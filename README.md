# CleanBro

Dua alat untuk melihat dan merapikan penggunaan disk di macOS:

- **`cekdisk`**: CLI Go untuk memindai ukuran folder secara paralel dan cepat, mirip `du`, dengan tampilan tree dan daftar file terbesar.
- **CleanBro**: aplikasi SwiftUI native untuk membersihkan file sampah, uninstall aplikasi, dan menganalisis disk.

## cekdisk (CLI)

### Build

Butuh Go (lihat versi di `go.mod`).

```sh
go build -o cekdisk .
```

### Pemakaian

```sh
cekdisk [opsi] [path]      # default path: ~
```

| Opsi | Default | Keterangan |
|------|---------|------------|
| `-d` | `1` | Kedalaman tree yang ditampilkan |
| `-n` | `20` | Jumlah folder teratas per level (`0` = semua) |
| `-f` | `15` | Tampilkan N file terbesar (`0` = mati) |
| `-x` | `false` | Jangan menyeberang ke filesystem/volume lain |
| `-j` | `CPU × 4` | Jumlah goroutine paralel |

Contoh:

```sh
cekdisk ~
cekdisk -d 2 -n 10 ~/Library
sudo cekdisk -d 1 /
```

Catatan:

- Ukuran yang dihitung adalah ukuran blok yang benar-benar terpakai di disk (seperti `du`), bukan ukuran logis file.
- Hardlink hanya dihitung sekali.
- `/Volumes`, `/System/Volumes`, dan `/dev` dilewati agar tidak terhitung dua kali, kecuali path itu sendiri yang dipindai.
- Kalau muncul peringatan "izin ditolak", jalankan dengan `sudo` atau beri **Full Disk Access** ke Terminal (System Settings → Privacy & Security).

## CleanBro (aplikasi macOS)

Butuh macOS 14 (Sonoma) atau lebih baru dan Swift 6 toolchain (Xcode 16+).

### Fitur

**Alat**
- **Pembersihan**: memindai dan menghapus cache aplikasi, log dan laporan crash, data developer (Xcode DerivedData, DeviceSupport, cache simulator, npm, Gradle, `~/.cache`), unduhan yang tidak selesai, dan isi Sampah.
- **Uninstall Aplikasi**: menghapus aplikasi beserta file pendukungnya.

**Analisis**
- **Penggunaan Disk**: tree ukuran folder.
- **File Besar**: file berukuran 100 MB ke atas.
- **Lama Tak Diubah**: file yang sudah lama tidak dimodifikasi.
- **File Duplikat**: deteksi duplikat berdasarkan ukuran lalu hash SHA-256.

File bisa dipindah ke Sampah atau dihapus permanen. Folder yang tidak ingin dipindai bisa diatur di Settings (⌘,).

### Build

```sh
cd CleanBro
./build.sh
open build/CleanBro.app
```

`build.sh` melakukan build release universal (Apple Silicon + Intel) dengan SwiftPM, merakit bundle `CleanBro.app` di `CleanBro/build/`, menandatanganinya secara ad-hoc, lalu membuat `CleanBro.zip` untuk dibagikan.

Untuk memakai di Mac lain, bagikan `CleanBro.zip` (jangan salin folder `.app` langsung). Karena belum dinotarisasi Apple, saat pertama dibuka macOS akan memblokirnya: buka **System Settings → Privacy & Security**, lalu klik **Open Anyway**. Atau lewat Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/CleanBro.app
```

Untuk development:

```sh
cd CleanBro
swift run
```

### Izin

Agar Sampah dan sebagian folder di `~/Library` bisa dibaca, beri CleanBro **Full Disk Access** di System Settings → Privacy & Security → Full Disk Access. Aplikasi akan menampilkan pengingat kalau izin ini belum diberikan.

## CI/CD

GitHub Actions ([`.github/workflows/build.yml`](.github/workflows/build.yml)) mem-build `CleanBro.app` dan `cekdisk` (universal) di setiap push ke `main` dan pull request. Hasil build bisa diunduh dari tab **Actions** sebagai artifact.

Untuk merilis, push tag versi. Workflow akan membuat GitHub Release berisi `CleanBro.zip`, `cekdisk-macos-universal.tar.gz`, dan `SHA256SUMS.txt`, dengan versi app diambil dari nama tag:

```sh
git tag v1.0.0
git push origin v1.0.0
```

## Struktur

```
.
├── main.go            # sumber cekdisk
├── go.mod
├── CleanBro/
│   ├── Package.swift
│   ├── build.sh       # build & bundle .app
│   └── Sources/CleanBro/
└── template/          # mockup desain UI (HTML)
```

## Lisensi

Copyright (C) 2026 gilang

Program ini adalah perangkat lunak bebas: kamu boleh menyebarkan dan/atau memodifikasinya di bawah ketentuan [GNU General Public License versi 3](LICENSE) seperti yang diterbitkan oleh Free Software Foundation.

Program ini disebarkan dengan harapan akan berguna, tetapi TANPA JAMINAN APA PUN. Lihat file [LICENSE](LICENSE) untuk detailnya.
