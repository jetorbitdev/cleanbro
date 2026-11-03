// cekdisk — fast parallel disk usage scanner for macOS.
package main

import (
	"container/heap"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type node struct {
	name     string
	size     int64 // allocated bytes (like du)
	files    int64
	children []*node
	mu       sync.Mutex
}

type fileEntry struct {
	path string
	size int64
}

// min-heap for top-N largest files
type fileHeap []fileEntry

func (h fileHeap) Len() int            { return len(h) }
func (h fileHeap) Less(i, j int) bool  { return h[i].size < h[j].size }
func (h fileHeap) Swap(i, j int)       { h[i], h[j] = h[j], h[i] }
func (h *fileHeap) Push(x interface{}) { *h = append(*h, x.(fileEntry)) }
func (h *fileHeap) Pop() interface{} {
	old := *h
	x := old[len(old)-1]
	*h = old[:len(old)-1]
	return x
}

type scanner struct {
	maxDepth  int
	topFiles  int
	oneFS     bool
	rootDev   int32
	sem       chan struct{}
	skip      map[string]bool
	errCount  atomic.Int64
	fileCount atomic.Int64
	dirCount  atomic.Int64
	inodes    sync.Map // hardlink dedupe
	hmu       sync.Mutex
	heap      fileHeap
}

func (s *scanner) addFile(path string, size int64) {
	if s.topFiles <= 0 {
		return
	}
	s.hmu.Lock()
	if len(s.heap) < s.topFiles {
		heap.Push(&s.heap, fileEntry{path, size})
	} else if size > s.heap[0].size {
		s.heap[0] = fileEntry{path, size}
		heap.Fix(&s.heap, 0)
	}
	s.hmu.Unlock()
}

// scan returns total allocated size and file count of dir.
// If keep is non-nil, child nodes are recorded (up to maxDepth).
func (s *scanner) scan(dir string, depth int, keep *node) (int64, int64) {
	s.dirCount.Add(1)
	f, err := os.Open(dir)
	if err != nil {
		s.errCount.Add(1)
		return 0, 0
	}
	names, err := f.Readdirnames(-1)
	f.Close()
	if err != nil && len(names) == 0 {
		s.errCount.Add(1)
		return 0, 0
	}

	var total, files int64
	var wg sync.WaitGroup
	var mu sync.Mutex

	for _, name := range names {
		p := dir + "/" + name
		if dir == "/" {
			p = "/" + name
		}
		var st syscall.Stat_t
		if err := syscall.Lstat(p, &st); err != nil {
			s.errCount.Add(1)
			continue
		}
		sz := st.Blocks * 512

		if st.Mode&syscall.S_IFMT == syscall.S_IFDIR {
			if s.skip[p] || (s.oneFS && st.Dev != s.rootDev) {
				continue
			}
			var child *node
			if keep != nil && depth < s.maxDepth {
				child = &node{name: name}
				keep.mu.Lock()
				keep.children = append(keep.children, child)
				keep.mu.Unlock()
			}
			work := func() {
				sub, subFiles := s.scan(p, depth+1, child)
				sub += sz
				if child != nil {
					child.size, child.files = sub, subFiles
				}
				mu.Lock()
				total += sub
				files += subFiles
				mu.Unlock()
			}
			select {
			case s.sem <- struct{}{}:
				wg.Add(1)
				go func() {
					defer wg.Done()
					work()
					<-s.sem
				}()
			default:
				work()
			}
			continue
		}

		// hardlink dedupe
		if st.Nlink > 1 && st.Mode&syscall.S_IFMT == syscall.S_IFREG {
			key := [2]uint64{uint64(st.Dev), st.Ino}
			if _, dup := s.inodes.LoadOrStore(key, struct{}{}); dup {
				continue
			}
		}
		s.fileCount.Add(1)
		mu.Lock()
		total += sz
		files++
		mu.Unlock()
		if st.Mode&syscall.S_IFMT == syscall.S_IFREG {
			s.addFile(p, sz)
		}
	}
	wg.Wait()
	return total, files
}

func human(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}

func bar(frac float64, width int) string {
	n := int(frac*float64(width) + 0.5)
	if n > width {
		n = width
	}
	return strings.Repeat("█", n) + strings.Repeat("░", width-n)
}

func printTree(n *node, parentSize int64, indent string, depth, maxDepth, limit int) {
	sort.Slice(n.children, func(i, j int) bool { return n.children[i].size > n.children[j].size })
	shown := n.children
	if limit > 0 && len(shown) > limit {
		shown = shown[:limit]
	}
	for _, c := range shown {
		frac := 0.0
		if parentSize > 0 {
			frac = float64(c.size) / float64(parentSize)
		}
		fmt.Printf("%10s  %s %5.1f%%  %s%s/\n", human(c.size), bar(frac, 20), frac*100, indent, c.name)
		if depth+1 < maxDepth {
			printTree(c, c.size, indent+"  ", depth+1, maxDepth, limit)
		}
	}
	if rest := len(n.children) - len(shown); rest > 0 {
		var restSize int64
		for _, c := range n.children[len(shown):] {
			restSize += c.size
		}
		fmt.Printf("%10s  %s         %s… %d folder lainnya\n", human(restSize), strings.Repeat(" ", 20), indent, rest)
	}
}

func main() {
	depth := flag.Int("d", 1, "kedalaman tree yang ditampilkan")
	limit := flag.Int("n", 20, "jumlah folder teratas per level (0 = semua)")
	top := flag.Int("f", 15, "tampilkan N file terbesar (0 = mati)")
	oneFS := flag.Bool("x", false, "jangan menyeberang ke filesystem/volume lain")
	workers := flag.Int("j", runtime.NumCPU()*4, "jumlah goroutine paralel")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Pemakaian: cekdisk [opsi] [path]   (default path: ~)\n\n")
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nContoh:\n  cekdisk ~\n  cekdisk -d 2 -n 10 ~/Library\n  sudo cekdisk -d 1 /\n")
	}
	flag.Parse()

	root := flag.Arg(0)
	if root == "" {
		root, _ = os.UserHomeDir()
	}
	root, _ = filepath.Abs(root)

	var st syscall.Stat_t
	if err := syscall.Stat(root, &st); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}

	s := &scanner{
		maxDepth: *depth,
		topFiles: *top,
		oneFS:    *oneFS,
		rootDev:  st.Dev,
		sem:      make(chan struct{}, *workers),
		// avoid double counting: other volumes & APFS data volume (reachable via firmlinks)
		skip: map[string]bool{"/Volumes": true, "/System/Volumes": true, "/dev": true},
	}
	delete(s.skip, root)

	start := time.Now()
	done := make(chan struct{})
	fi, _ := os.Stderr.Stat()
	isTTY := fi != nil && fi.Mode()&os.ModeCharDevice != 0
	go func() {
		if !isTTY {
			<-done
			return
		}
		t := time.NewTicker(200 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-done:
				fmt.Fprint(os.Stderr, "\r\033[K")
				return
			case <-t.C:
				fmt.Fprintf(os.Stderr, "\r\033[Kmemindai… %d folder, %d file", s.dirCount.Load(), s.fileCount.Load())
			}
		}
	}()

	rootNode := &node{name: root}
	total, files := s.scan(root, 0, rootNode)
	rootNode.size = total
	close(done)
	elapsed := time.Since(start)

	fmt.Printf("\n📁 %s  —  total %s, %d file, %d folder  (%.2fs)\n\n",
		root, human(total), files, s.dirCount.Load(), elapsed.Seconds())
	printTree(rootNode, total, "", 0, *depth, *limit)

	if *top > 0 && len(s.heap) > 0 {
		sort.Slice(s.heap, func(i, j int) bool { return s.heap[i].size > s.heap[j].size })
		fmt.Printf("\n📄 %d file terbesar:\n", len(s.heap))
		for _, f := range s.heap {
			fmt.Printf("%10s  %s\n", human(f.size), f.path)
		}
	}

	var fs syscall.Statfs_t
	if syscall.Statfs(root, &fs) == nil {
		sz := int64(fs.Blocks) * int64(fs.Bsize)
		free := int64(fs.Bavail) * int64(fs.Bsize)
		fmt.Printf("\n💾 Volume: %s terpakai dari %s, sisa %s\n", human(sz-free), human(sz), human(free))
	}
	if e := s.errCount.Load(); e > 0 {
		fmt.Printf("⚠️  %d item tidak bisa dibaca (izin ditolak). Coba jalankan dengan sudo, atau beri Full Disk Access ke Terminal.\n", e)
	}
}
