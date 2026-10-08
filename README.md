# Arsitektur Sistem

## 1. Bagian Interface

### a. Input Interface
![Input interface](Input_Interface.png)
Aliran Data: `HPS Side (AXI3 Master, 64 bit) -> h2f bridge -> FPGA Side (AXI3 Slave, 64 bit) -> Input FIFO -> Core Side (AXI4 Stream-Master, 64 bit)`

| Nama Block | Size | Deskripsi |
| :--- | :--- | :--- |
| **Address_In** | 32 bit | Ini adalah alamat penulisan AXI3. Pengontrol DMA HPS menggunakan alamat 32-bit ini untuk menentukan di mana data dokumen yang masuk harus ditulis pada ruang *memory-mapped* FPGA. Karena Cyclone V menggunakan ruang alamat 32-bit untuk *bridge* HPS-ke-FPGA, lebar ini cukup untuk mengalamatkan hingga 4 GB ruang *slave* FPGA. |
| **Data_In** | 64 bit | Ini adalah muatan (*payload*) data penulisan AXI3. Jalur ini membawa byte mentah dari dokumen PDF e-Meterai dari DDR3 HPS ke dalam *fabric* FPGA. Lebar 64-bit menyesuaikan dengan bus memori DDR3 HPS dan ukuran kata (*word size*) bawaan SHA-512, memastikan transfer data yang efisien tanpa *overhead* pengepakan atau *padding*. |
| **BRESP** | 2 bit | Ini adalah saluran Respons Penulisan AXI3. Setelah Input FIFO berhasil menerima rentetan (*burst*) data, ia mengaktifkan BRESP untuk mengonfirmasi penulisan. Kode 2-bit menunjukkan status: 00 (OKAY), 01 (EXOKAY), 10 (SLVERR), atau 11 (DECERR). Ini memberitahu pengontrol DMA HPS apakah transfer berhasil atau terjadi kesalahan. |
| **l3_main_clk** | 1 bit | Ini adalah *clock* utama untuk interkoneksi L3 HPS. Ini adalah domain *clock* tempat ARM Cortex-A9 dan pengontrol DMA-nya beroperasi (biasanya sekitar 100-200 MHz pada DE10-Nano). *Bridge* h2f menggunakan *clock* ini pada antarmuka sisi HPS-nya. |
| **TDATA** | 64 bit | Ini adalah muatan data AXI4-Stream. Jalur ini membawa byte dokumen dari Input FIFO ke *Implementation Plane* SHA-512. Berbeda dengan antarmuka AXI3 yang *memory-mapped*, TDATA tidak memiliki alamat—ini adalah aliran kontinu kata 64-bit yang akan dirakit oleh *Block Splitter* menjadi blok 1024-bit untuk pemrosesan SHA-512. |
| **TVALID** | 1 bit | Ini adalah sinyal valid AXI4-Stream. Saat diaktifkan (*asserted*), ini menunjukkan bahwa data pada TDATA valid dan siap dikonsumsi oleh *Block Splitter*. Sinyal ini bekerja bersama TREADY (yang mengarah ke kiri, dari *Block Splitter* kembali ke FIFO) untuk mengimplementasikan *handshake* standar AXI-Stream. |
| **TLAST** | 1 bit | Ini adalah sinyal terakhir AXI4-Stream. Sinyal ini diaktifkan pada kata 64-bit terakhir dari sebuah dokumen. Ini memberitahu *Block Splitter* bahwa dokumen saat ini telah berakhir, memicu logika *padding* SHA-512 (menambahkan bit 1, angka nol, dan panjang field 128-bit) sebelum blok terakhir di-hash. |
| **TUSER** | 16 bit | Ini adalah sinyal *sideband* pengguna AXI4-Stream, yang membawa ID Pekerjaan (Job ID). HPS menetapkan ID 16-bit ini ke setiap dokumen sebelum mengirimkannya. Input FIFO meneruskannya bersama data dokumen sehingga *core* SHA-512 dapat menyimpannya selama komputasi. Ini memastikan hasil *hash* akhir dapat dicocokkan kembali ke PDF yang benar. |
| **h2f_axi_clk** | 1 bit | Ini adalah *clock* sisi FPGA untuk *bridge* HPS-ke-FPGA. *Clock* ini dihasilkan oleh *fabric* FPGA (biasanya 50-100 MHz pada DE10-Nano) dan digunakan oleh antarmuka *slave* AXI3 pada Input FIFO. *Bridge* h2f secara internal menangani persilangan domain *clock* (*clock domain crossing*). |
| **core_clk** | 1 bit | Ini adalah domain *clock* untuk *Implementation Plane* SHA-512. *Clock* ini menggerakkan sisi pembacaan dari FIFO *dual-clock* milik Input FIFO dan logika *Block Splitter*. |

### b. Output Interface
Aliran Data: `Core Side (AXI4 Stream-Slave, 512 bit) -> Output FIFO -> FPGA Side (AXI3 Master, 64 bit) -> f2h bridge -> HPS Side (AXI3 Slave, 64 bit)`

| Nama Block | Size | Deskripsi |
| :--- | :--- | :--- |
| **Address_Out**| 32 bit | Ini adalah alamat penulisan AXI3. Output FIFO menghasilkan alamat 32-bit ini untuk memberitahu *bridge* f2h di mana paket hasil harus ditulis pada DDR3 HPS. Driver mengalokasikan *buffer* hasil di DDR3 dan memprogram alamat dasarnya ke dalam register kontrol Output FIFO. |
| **Data_Out** | 64 bit | Ini adalah muatan data penulisan AXI3. Jalur ini membawa paket hasil (Job ID + *digest* SHA-512 512-bit) dari Output FIFO ke DDR3 HPS. Output FIFO secara internal membagi *digest* 512-bit menjadi 8 x kata 64-bit agar sesuai dengan lebar bus ini. |
| **BRESP** | 2 bit | Ini adalah saluran Respons Penulisan AXI3. Setelah *bridge* f2h berhasil menulis paket hasil ke DDR3 HPS, ia mengaktifkan BRESP untuk mengonfirmasi penulisan. FSM *Master* AXI3 pada Output FIFO menunggu respons ini sebelum mengirim paket hasil berikutnya. |
| **l3_main_clk**| 1 bit | Ini adalah *clock* utama untuk interkoneksi L3 HPS. *Bridge* f2h menggunakan *clock* ini pada antarmuka sisi HPS-nya untuk meneruskan paket hasil ke pengontrol memori DDR3. |
| **TDATA** | 512 bit| Ini adalah muatan data AXI4-Stream. Jalur ini membawa *digest* SHA-512 512-bit dari *Result Aggregator* ke Output FIFO. Karena SHA-512 secara bawaan menghasilkan *output* 512-bit, antarmuka ini selebar 512 bit, memungkinkan seluruh *digest* ditransfer dalam satu siklus *clock*. |
| **TVALID** | 1 bit | Ini adalah sinyal valid AXI4-Stream. Saat diaktifkan, ini menunjukkan bahwa *digest* 512-bit pada TDATA valid dan siap ditulis ke dalam Output FIFO. |
| **TLAST** | 1 bit | Ini adalah sinyal terakhir AXI4-Stream. Sinyal ini diaktifkan untuk menandai akhir dari paket hasil. |
| **TUSER** | 16 bit | Ini adalah sinyal *sideband* pengguna AXI4-Stream, yang membawa ID Pekerjaan (Job ID). *Result Aggregator* memasang kembali Job ID tersebut ke *digest* 512-bit. |
| **f2h_axi_clk**| 1 bit | Ini adalah *clock* sisi FPGA untuk *bridge* FPGA-ke-HPS. Dihasilkan oleh *fabric* FPGA (biasanya 50-100 MHz pada DE10-Nano) dan digunakan oleh antarmuka *master* AXI3 pada Output FIFO. |
| **core_clk** | 1 bit | Ini adalah domain *clock* untuk *Implementation Plane* SHA-512. Menggerakkan sisi penulisan dari FIFO *dual-clock* milik Output FIFO dan logika *Result Aggregator*. |

---

## 2. Bagian FSM (Finite State Machine) & Register

### Register Control Bank

| Blok Register | Offset | Akses | Deskripsi |
| :--- | :--- | :--- | :--- |
| **CTRL** | `0x00` | R/W | **Bit [0] START:** Tulis 1 untuk memulai pemrosesan.<br>**Bit [1] RESET:** Tulis 1 untuk mereset semua *core* SHA-512 dan FIFO internal.<br>**Bit [2] FLUSH:** Tulis 1 untuk mengosongkan (*flush*) Input/Output FIFO.<br>**Bit [3] IRQ_GLOBAL_EN:** Mengaktifkan interupsi global.<br>**Bits [7:4] CORE_COUNT:** Jumlah *core* aktif (1-16).<br>**Bits [31:8]:** Dipesan/Reserved (0). |
| **STATUS** | `0x04` | R | **Bit [0] BUSY:** 1 jika ada *core* aktif yang sedang bekerja.<br>**Bit [1] DONE:** 1 jika semua pekerjaan yang dikirimkan telah selesai.<br>**Bit [2] ERROR:** 1 jika terjadi kesalahan.<br>**Bit [3] IDLE:** 1 jika semua *core* menganggur (*idle*).<br>**Bits [31:4]:** Dipesan/Reserved. |
| **CORE_EN** | `0x08` | R/W | **Bits [15:0]:** Setiap bit mengaktifkan/menonaktifkan *core* SHA-512 tertentu (contoh: Bit 0 = Core 0).<br>**Bits [31:16]:** Dipesan/Reserved (0). |
| **IRQ_EN** | `0x0C` | R/W | **Bit [0]:** Aktifkan interupsi penyelesaian pekerjaan.<br>**Bit [1]:** Aktifkan interupsi kesalahan.<br>**Bit [2]:** Aktifkan interupsi *overflow* pada FIFO. |
| **IRQ_STATUS**| `0x10` | R/W1C| **Bit [0]:** Interupsi penyelesaian pekerjaan tertunda (*pending*).<br>**Bit [1]:** Interupsi kesalahan tertunda.<br>**Bit [2]:** Interupsi FIFO *overflow* tertunda. (Tulis 1 untuk menghapus/clear). |
| **JOB_BASE** | `0x14` | R/W | **Bits [31:0]:** Alamat fisik 32-bit di DDR3 HPS tempat antrean deskriptor pekerjaan berada. |
| **JOB_COUNT** | `0x18` | R/W | **Bits [31:0]:** Jumlah pekerjaan yang saat ini ada di dalam antrean. |
| **VERSION** | `0x1C` | R | **Bits [31:0]:** Nilai 32-bit bawaan (*hardcoded*) (contoh: 0x00010001) untuk validasi driver. |
| **CORE_STATUS**| `0x20` | R | **Bits [15:0]:** Status sibuk/menganggur dari *core* tertentu (1=Sibuk, 0=Menganggur). |
| **ERROR_FLAGS**| `0x24` | R/W1C| **Bit [0]:** Kesalahan protokol AXI.<br>**Bit [1]:** *Time out* pada *core*.<br>**Bit [2]:** FIFO *underflow*/*overflow*. |

### Fungsi Blok FSM

| Fungsi | Deskripsi |
| :--- | :--- |
| **Writing** | **IDLE:** Menunggu AWVALID.<br>**WRITE_ADDR:** Menangkap AWADDR, mengaktifkan AWREADY.<br>**WRITE_DATA:** Menangkap WDATA/WSTRB, mengaktifkan WREADY.<br>**WRITE_REG:** Mengaktifkan pulsa `reg_wr_en`. Menulis WDATA ke AWADDR.<br>**WRITE_RESP:** Mengaktifkan BVALID, mengatur BRESP = 00 (OKAY).<br>**DONE:** Kembali ke IDLE. |
| **Reading** | **IDLE:** Menunggu ARVALID.<br>**READ_ADDR:** Menangkap ARADDR, mengaktifkan ARREADY.<br>**READ_REG:** Mengatur `reg_addr` ke ARADDR, menempatkan nilai pada `reg_rdata`.<br>**READ_DATA:** Menangkap `reg_rdata`, mengaktifkan RVALID, mengatur RRESP = 00.<br>**DONE:** Kembali ke IDLE. |

### Blok Kontrol Lainnya

| Blok | Deskripsi |
| :--- | :--- |
| **Core Manager** | **Clock Gating/Power Saving:** Membaca `CORE_EN`. Mematikan *clock* dan menahan *reset* untuk *core* yang dinonaktifkan. Mengaktifkan *clock* dan melepas *reset* untuk *core* yang diaktifkan.<br>**Job Launch:** Memantau `CTRL[START]=1` untuk mengizinkan *core* menarik data.<br>**Completion Tracking:** Memantau `core_done`. Mengaktifkan `all_done` saat selesai, memperbarui `STATUS[DONE]=1`. |
| **Interrupt Controller & HPS GIC** | **FPGA Side:** Mengatur bit-bit `IRQ_STATUS` berdasarkan `core_done` atau jika ada kesalahan. Jika diaktifkan melalui `IRQ_EN`, maka akan mengaktifkan jalur kabel `fpga_irq`.<br>**HPS GIC:** Memetakan `fpga_irq` ke ID IRQ tertentu (misal: 72), menginterupsi CPU ARM, dan melompat ke *handler* driver Linux. |

---

## 3. Bagian SHA-512

| Blok | Deskripsi |
| :--- | :--- |
| **Block Splitter** | Bertindak sebagai jembatan antara dunia *streaming* 64-bit (Interface) dan dunia blok 1024-bit dari SHA-512. Mengumpulkan kata 64-bit menjadi blok 1024-bit. Menangani *padding* kriptografi wajib (menambahkan 1 bit, deretan angka nol, dan panjang dokumen 128-bit) saat `TLAST` diaktifkan. Menangkap dan meneruskan ID Pekerjaan (`TUSER`). |
| **Work Dispatcher** | Pengontrol lalu lintas dan penjadwal. Melakukan paralelisasi di tingkat dokumen (dokumen berbeda diarahkan ke *core* yang berbeda) karena SHA-512 pada dasarnya bersifat sekuensial per dokumen. Menggunakan kebijakan *First-Free*/*Round-Robin* untuk menugaskan dokumen baru ke *core* yang menganggur. Memelihara tabel pelacakan (Job ID -> Core) untuk mengarahkan blok-blok berikutnya secara berurutan. |
| **12 Core SHA-512**| Susunan (*array*) mesin kriptografi aktual yang mengeksekusi algoritma SHA-512 melintasi 12 *core* paralel. |
| **Result Aggregator**| Tahap pengumpulan akhir. Menangani penyelesaian yang tidak berurutan (*out-of-order*) dari *core* menggunakan *arbiter round-robin*. Memasangkan *digest* 512-bit dengan ID Pekerjaannya (`TUSER`). Mengemasnya ke dalam ketukan (*beat*) AXI4-Stream tunggal (`TVALID=1`, `TLAST=1`) dan mengirimkannya ke Output FIFO. |

---

## 4. Bagian Software

| Blok | Deskripsi |
| :--- | :--- |
| **Application Interface** | Program yang berhadapan langsung dengan pengguna (CLI, server Web, atau pemroses *batch*). Menerjemahkan permintaan manusia/sistem menjadi pemanggilan *library*. Memanggil `sha512_verify_file(path)` dan melaporkan VERIFY_OK, VERIFY_TAMPERED, atau VERIFY_ERROR. |
| **User Space Library** | *Library* bersama (`.so`) yang menyembunyikan kerumitan pemisahan (*parsing*) PDF, ekstraksi X.509, dan interaksi driver. Membuka PDF, mencari `/ByteRange` dan `/Contents`, memilah PKCS#7 untuk mengekstrak X.509 dan *hash* yang diharapkan. Membuka `/dev/sha512`, mengalokasikan pekerjaan, mengirim data via `write()` atau `mmap()`, membaca hasil komputasi *hash* via `read()`, dan membandingkannya. |
| **Kernel Driver** | Driver perangkat karakter (`/dev/sha512`) yang mengelola register FPGA, DMA, dan interupsi. Meliputi:<br>- `probe()`: ioremap, alokasi DMA, permintaan IRQ.<br>- `open()` / `release()`: Manajemen sesi.<br>- `ioctl()`: Mengatur *core*, mengirimkan pekerjaan, melakukan *reset*.<br>- `write()`: Memprogram DMA PL330, menulis register, memicu dimulainya proses.<br>- `read()`: Menunggu di antrean, membatalkan (*invalidate*) *cache* CPU, menyalin hasil ke *user space*.<br>- `Interrupt Handler`: Menghapus IRQ, membaca hasil, membangunkan proses yang menunggu. |
| **DMA Engine Integration** | Subsistem `dmaengine` pada kernel Linux. API abstrak untuk DMA PL330. Menggunakan `dma_request_channel()`, `dmaengine_prep_dma_memcpy()`, dan `dmaengine_submit()` untuk menangani transfer memori secara efisien melalui *callback*. |


# Hasil Simulasi RTL — SHA-512 Multi-Core Accelerator

Seluruh digest dibandingkan dengan model referensi Python `hashlib.sha512`.

| Item | Nilai |
|---|---|
| Simulator | Icarus Verilog (`iverilog -g2005`) |
| Clock | `core_clk` 50 MHz, `h2f_axi_clk` 100 MHz |
| Model memori | DDR3  |
| Cara menjalankan | `cd sim && ./run_sim.sh` |

## Ringkasan

✅ **Semua 13 skenario lulus — 0 mismatch digest.**

| Skenario | Konfigurasi | Hasil |
|---|---|---|
| Kasus tepi panjang pesan (20 dokumen: 0, 1, 7, 8, 111–129 B, lintas batas 4 KB, …) | N = 1, 4, 12 | ✅ 20/20 |
| Dokumen besar (12 × 4 KB) | N = 1, 4, 12 | ✅ 12/12 |
| Dokumen kecil (48 × 64 B) | N = 1, 4, 12 | ✅ 48/48 |
| Backpressure acak pada jalur baca/tulis | N = 6 | ✅ 20/20 |
| SLVERR di tengah burst → RESET → proses ulang | N = 4 | ✅ ERROR terdeteksi, lalu 20/20 |
| RESET di tengah proses (siklus ke-777) | N = 5 | ✅ kembali IDLE dalam 44 siklus, lalu 20/20 |
| Push mode (AXI3 slave, Job ID = nomor urut) | N = 4 | ✅ 20/20 |

## Kinerja

### Dokumen besar (12 × 4 KB = 49.152 B)

| N core | Siklus | Waktu @ 50 MHz | Throughput | Speedup vs N = 1 | Core aktif maks. |
|---:|---:|---:|---:|---:|---:|
| 1 | 32.555 | 651 µs | ≈ 75 MB/s | 1,0× | 1 |
| 4 | 8.995 | 180 µs | ≈ 273 MB/s | 3,6× | 4 |
| 12 | 8.475 | 170 µs | ≈ 290 MB/s | 3,8× | 5 |

### Dokumen kecil (48 × 64 B)

| N core | Siklus | Waktu @ 50 MHz | Dokumen/detik | Speedup vs N = 1 | Core aktif maks. |
|---:|---:|---:|---:|---:|---:|
| 1 | 4.130 | 82,6 µs | ≈ 0,58 juta | 1,0× | 1 |
| 4 | 1.140 | 22,8 µs | ≈ 2,1 juta | 3,6× | 4 |
| 12 | 1.080 | 21,6 µs | ≈ 2,2 juta | 3,8× | 5 |

### Kasus tepi (20 dokumen campuran)

| N core | Siklus | Speedup vs N = 1 |
|---:|---:|---:|
| 1 | 7.650 | 1,0× |
| 4 | 4.195 | 1,8× |
| 12 | 4.210 | 1,8× |

## Analisis

- **Satu core:** 128 B per ~82 siklus ≈ 78 MB/s pada 50 MHz. Hasil N = 1 (≈ 75 MB/s).
- **Saturasi di ~5 core.** Jalur baca 64 bit @ 50 MHz butuh ~18 siklus per blok 128 B, sedangkan core butuh ~82 siklus, sehingga hanya ~82 / 18 ≈ 4,6 core yang dapat disuplai penuh. Karena itu N = 12 hampir tidak lebih cepat dari N = 4.
- **Kasus tepi** berisi banyak dokumen sangat kecil, sehingga waktu baca descriptor lebih dominan dan speedup lebih rendah.
- **Peningkatan berikutnya:** bridge FPGA-to-HPS 128 bit, clock DMA lebih tinggi, dan beberapa read outstanding.

## Log lengkap

<details>
<summary>Tampilan keluaran <code>run_sim.sh</code></summary>

```text
== pull mode, edge docs, N=1
STATUS=0000000a after 7650 core cycles, max cores busy simultaneously=1, 4KB-crossing bursts=0
20/20 correct
== pull mode, edge docs, N=4
STATUS=0000000a after 4195 core cycles, max cores busy simultaneously=4, 4KB-crossing bursts=0
20/20 correct
== pull mode, edge docs, N=12
STATUS=0000000a after 4210 core cycles, max cores busy simultaneously=5, 4KB-crossing bursts=0
20/20 correct
== pull mode, big docs, N=1
STATUS=0000000a after 32555 core cycles, max cores busy simultaneously=1, 4KB-crossing bursts=0
12/12 correct
== pull mode, big docs, N=4
STATUS=0000000a after 8995 core cycles, max cores busy simultaneously=4, 4KB-crossing bursts=0
12/12 correct
== pull mode, big docs, N=12
STATUS=0000000a after 8475 core cycles, max cores busy simultaneously=5, 4KB-crossing bursts=0
12/12 correct
== pull mode, small docs, N=1
STATUS=0000000a after 4130 core cycles, max cores busy simultaneously=1, 4KB-crossing bursts=0
48/48 correct
== pull mode, small docs, N=4
STATUS=0000000a after 1140 core cycles, max cores busy simultaneously=4, 4KB-crossing bursts=0
48/48 correct
== pull mode, small docs, N=12
STATUS=0000000a after 1080 core cycles, max cores busy simultaneously=5, 4KB-crossing bursts=0
48/48 correct
== random backpressure
STATUS=0000000a after 4395 core cycles, max cores busy simultaneously=4, 4KB-crossing bursts=0
20/20 correct
== SLVERR mid-burst -> RESET -> rerun
ERROR RUN: STATUS=00000005 (expect ERROR bit2), dma state=0, rd_active=0
STATUS=0000000a after 4325 core cycles, max cores busy simultaneously=4, 4KB-crossing bursts=0
20/20 correct
== RESET in the middle of a run
MID-RUN RESET at 777 cycles: dma_st=7 out_st=0 in_flight_rd=1 tb_wr_slave=0
  back to IDLE after 44 cycles, tb_wr_slave=0 rd_active=0 (both must be 0)
STATUS=0000000a after 4340 core cycles, max cores busy simultaneously=4, 4KB-crossing bursts=0
20/20 correct
== push mode (AXI3 slave, job ID = sequence number)
STATUS=0000000a after 6407 core cycles, max cores busy simultaneously=4, 4KB-crossing bursts=0
20/20 correct
```

</details>

**Keterangan:** `STATUS=0000000a` = bit DONE dan IDLE menyala (selesai normal). `STATUS=00000005` = BUSY dan ERROR.
