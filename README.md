[Untitled Diagram5.drawio](https://github.com/user-attachments/files/33190147/Untitled.Diagram5.drawio)# Arsitektur Sistem

## 1. Bagian Interface

### a. Input Interface
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
[Uploading Un<mxfile host="app.diagrams.net">
  <diagram name="Page-1" id="ONAPuBuzvhCbw7s-ajzx">
    <mxGraphModel dx="1016" dy[Uploading Untitled Diagram3.drawio…]()
[Untitled Diagram2.drawio](https://github.com/user-attachments/files/33190157/Untitled.Diagram2.drawio)
[Untitled Diagram.drawio](https://github.com/user-attachments/files/33190156/Untitled.Diagram.drawio)
="594" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="850" pageHeight="1100" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
        <UserObject label="" mermaidData="{&#xa;  &quot;data&quot;: &quot;stateDiagram-v2\n    [*] --&gt; IDLE\n    IDLE --&gt; PREPARE_SCHEDULE : valid=1 dari Dispatcher\n    PREPARE_SCHEDULE --&gt; COMPRESSION_LOOP : Inisialisasi selesai\n    COMPRESSION_LOOP --&gt; COMPRESSION_LOOP : Counter &lt; 79 (80 ronde)\n    COMPRESSION_LOOP --&gt; UPDATE_STATE : Counter = 79\n    UPDATE_STATE --&gt; IDLE : Belum blok terakhir (tunggu lanjutannya)\n    UPDATE_STATE --&gt; DONE : Blok terakhir selesai\n    DONE --&gt; IDLE : Hasil diambil Result Aggregator&quot;,&#xa;  &quot;config&quot;: null,&#xa;  &quot;version&quot;: &quot;12&quot;&#xa;}" id="16">
          <mxCell connectable="0" parent="1" style="group;transparentBounds=1;editIcon=1;lockedGroup=0;groupPadding=10;" vertex="1">
            <mxGeometry as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="IDLE" mermaidId="n:IDLE" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="IDLE" id="3">
          <mxCell parent="16" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="432" y="66" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="PREPARE_SCHEDULE" mermaidId="n:PREPARE_SCHEDULE" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="PREPARE_SCHEDULE" id="4">
          <mxCell parent="16" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;labelWidth=120;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="200" y="204" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="COMPRESSION_LOOP" mermaidId="n:COMPRESSION_LOOP" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="COMPRESSION_LOOP" id="5">
          <mxCell parent="16" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;labelWidth=120;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="200" y="343" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="UPDATE_STATE" mermaidId="n:UPDATE_STATE" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="UPDATE_STATE" id="6">
          <mxCell parent="16" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="316" y="481" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="DONE" mermaidId="n:DONE" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="DONE" id="7">
          <mxCell parent="16" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="408" y="619" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="valid=1 dari Dispatcher" mermaidId="e:IDLE-&gt;PREPARE_SCHEDULE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.28;exitY=1;entryX=0.5;entryY=0.01;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="valid=1 dari Dispatcher" id="9">
          <mxCell edge="1" parent="16" source="3" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0;exitY=0.5;entryX=0.5;entryY=0.01;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;" target="4">
            <mxGeometry relative="1" x="0.164" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Inisialisasi selesai" mermaidId="e:PREPARE_SCHEDULE-&gt;COMPRESSION_LOOP#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Inisialisasi selesai" id="10">
          <mxCell edge="1" parent="16" source="4" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" target="5">
            <mxGeometry relative="1" as="geometry">
              <Array as="points" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="Counter &amp;lt; 79 (80 ronde)" mermaidId="e:COMPRESSION_LOOP-&gt;COMPRESSION_LOOP#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0;exitY=0.43;entryX=0;entryY=0.55;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Counter &lt; 79 (80 ronde)" id="11">
          <mxCell edge="1" parent="16" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;">
            <mxGeometry relative="1" x="0.2489" as="geometry">
              <Array as="points">
                <mxPoint x="90" y="400" />
                <mxPoint x="90" y="320" />
                <mxPoint x="234" y="320" />
              </Array>
              <mxPoint x="270" y="410" as="sourcePoint" />
              <mxPoint x="270" y="320" as="targetPoint" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="Counter = 79" mermaidId="e:COMPRESSION_LOOP-&gt;UPDATE_STATE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=0.99;entryX=0.36;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Counter = 79" id="12">
          <mxCell edge="1" parent="16" source="5" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=none;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=0.99;entryX=0;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;" target="6">
            <mxGeometry relative="1" x="-0.2486" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Belum blok terakhir (tunggu lanjutannya)" mermaidId="e:UPDATE_STATE-&gt;IDLE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.64;exitY=0;entryX=0.5;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Belum blok terakhir (tunggu lanjutannya)" id="13">
          <mxCell edge="1" parent="16" source="6" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=1;exitY=0.5;entryX=0.5;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;" target="3">
            <mxGeometry relative="1" x="-0.0641" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Blok terakhir selesai" mermaidId="e:UPDATE_STATE-&gt;DONE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=1;entryX=0.36;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Blok terakhir selesai" id="14">
          <mxCell edge="1" parent="16" source="6" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=1;entryX=0;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;" target="7">
            <mxGeometry relative="1" x="-0.2735" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Hasil diambil Result Aggregator" mermaidId="e:DONE-&gt;IDLE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.64;exitY=0;entryX=0.71;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Hasil diambil Result Aggregator" id="15">
          <mxCell edge="1" parent="16" source="7" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=1;exitY=0.5;entryX=1;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;exitDx=0;exitDy=0;" target="3">
            <mxGeometry relative="1" x="-0.0117" as="geometry">
              <Array as="points">
                <mxPoint x="664" y="637.5" />
                <mxPoint x="664" y="84.5" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>

<mxfile host="app.diagrams.net">
  <diagram name="Page-1" id="Em8QSCZR3o66ie2OzRql">
    <mxGraphModel dx="1239" dy="724" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="850" pageHeight="1100" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
        <UserObject label="" mermaidData="{&#xa;  &quot;data&quot;: &quot;stateDiagram-v2\n    [*] --&gt; SYS_IDLE\n    SYS_IDLE --&gt; SYS_SETUP : Permintaan dari User Space\n    SYS_SETUP --&gt; SYS_KICK_HW : Salin PDF &amp; Alokasi DMA Buffer\n    SYS_KICK_HW --&gt; SYS_WAIT_HW : Tulis Register (START=1)\n    SYS_WAIT_HW --&gt; SYS_COMPLETE : Menunggu IRQ (FPGA Bekerja)\n    SYS_COMPLETE --&gt; SYS_IDLE : fpga_irq terpicu, Baca Hasil&quot;,&#xa;  &quot;config&quot;: null,&#xa;  &quot;version&quot;: &quot;12&quot;&#xa;}" id="8hYolZAXGm6dQjdigBHz-3">
          <mxCell connectable="0" parent="1" style="group;transparentBounds=1;editIcon=1;lockedGroup=0;groupPadding=10;fontColor=default;labelBackgroundColor=none;" vertex="1">
            <mxGeometry as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="" mermaidId="n:root_start" mermaidBaseStyle="ellipse;html=1;fillColor=#000000;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;strokeWidth=1;shadow=1;shadowColor=#000000;shadowOffsetX=2;shadowOffsetY=2;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="" id="8hYolZAXGm6dQjdigBHz-16">
          <mxCell parent="8hYolZAXGm6dQjdigBHz-3" style="ellipse;html=1;fillColor=#000000;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;strokeWidth=1;shadow=1;shadowColor=#000000;shadowOffsetX=2;shadowOffsetY=2;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="14" width="14" x="582" y="240" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="SYS_IDLE" mermaidId="n:SYS_IDLE" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="SYS_IDLE" id="8hYolZAXGm6dQjdigBHz-17">
          <mxCell parent="8hYolZAXGm6dQjdigBHz-3" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="522" y="294" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="SYS_SETUP" mermaidId="n:SYS_SETUP" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="SYS_SETUP" id="8hYolZAXGm6dQjdigBHz-18">
          <mxCell parent="8hYolZAXGm6dQjdigBHz-3" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="420" y="432" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="SYS_KICK_HW" mermaidId="n:SYS_KICK_HW" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="SYS_KICK_HW" id="8hYolZAXGm6dQjdigBHz-19">
          <mxCell parent="8hYolZAXGm6dQjdigBHz-3" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="420" y="571" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="SYS_WAIT_HW" mermaidId="n:SYS_WAIT_HW" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="SYS_WAIT_HW" id="8hYolZAXGm6dQjdigBHz-20">
          <mxCell parent="8hYolZAXGm6dQjdigBHz-3" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="420" y="709" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="SYS_COMPLETE" mermaidId="n:SYS_COMPLETE" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="SYS_COMPLETE" id="8hYolZAXGm6dQjdigBHz-21">
          <mxCell parent="8hYolZAXGm6dQjdigBHz-3" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="522" y="847" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="" mermaidId="e:root_start-&gt;SYS_IDLE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;exitX=0.54;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="" id="8hYolZAXGm6dQjdigBHz-22">
          <mxCell edge="1" parent="8hYolZAXGm6dQjdigBHz-3" source="8hYolZAXGm6dQjdigBHz-16" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;exitX=0.54;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" target="8hYolZAXGm6dQjdigBHz-17">
            <mxGeometry relative="1" as="geometry">
              <Array as="points" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="Permintaan dari User Space" mermaidId="e:SYS_IDLE-&gt;SYS_SETUP#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.35;exitY=1;entryX=0.5;entryY=0.01;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Permintaan dari User Space" id="8hYolZAXGm6dQjdigBHz-23">
          <mxCell edge="1" parent="8hYolZAXGm6dQjdigBHz-3" source="8hYolZAXGm6dQjdigBHz-17" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0;exitY=0.5;entryX=0.5;entryY=0.01;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;" target="8hYolZAXGm6dQjdigBHz-18">
            <mxGeometry relative="1" x="0.2657" as="geometry">
              <Array as="points">
                <mxPoint x="488" y="312.5" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="Salin PDF &amp;amp; Alokasi DMA Buffer" mermaidId="e:SYS_SETUP-&gt;SYS_KICK_HW#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Salin PDF &amp; Alokasi DMA Buffer" id="8hYolZAXGm6dQjdigBHz-24">
          <mxCell edge="1" parent="8hYolZAXGm6dQjdigBHz-3" source="8hYolZAXGm6dQjdigBHz-18" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" target="8hYolZAXGm6dQjdigBHz-19">
            <mxGeometry relative="1" as="geometry">
              <Array as="points" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="Tulis Register (START=1)" mermaidId="e:SYS_KICK_HW-&gt;SYS_WAIT_HW#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=0.99;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Tulis Register (START=1)" id="8hYolZAXGm6dQjdigBHz-25">
          <mxCell edge="1" parent="8hYolZAXGm6dQjdigBHz-3" source="8hYolZAXGm6dQjdigBHz-19" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=0.99;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" target="8hYolZAXGm6dQjdigBHz-20">
            <mxGeometry relative="1" as="geometry">
              <Array as="points" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="Menunggu IRQ (FPGA Bekerja)" mermaidId="e:SYS_WAIT_HW-&gt;SYS_COMPLETE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=1;entryX=0.35;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Menunggu IRQ (FPGA Bekerja)" id="8hYolZAXGm6dQjdigBHz-26">
          <mxCell edge="1" parent="8hYolZAXGm6dQjdigBHz-3" source="8hYolZAXGm6dQjdigBHz-20" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=1;entryX=0;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;" target="8hYolZAXGm6dQjdigBHz-21">
            <mxGeometry relative="1" x="-0.2704" as="geometry">
              <Array as="points">
                <mxPoint x="488" y="865.5" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="fpga_irq terpicu, Baca Hasil" mermaidId="e:SYS_COMPLETE-&gt;SYS_IDLE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.64;exitY=0;entryX=0.64;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="fpga_irq terpicu, Baca Hasil" id="8hYolZAXGm6dQjdigBHz-27">
          <mxCell edge="1" parent="8hYolZAXGm6dQjdigBHz-3" source="8hYolZAXGm6dQjdigBHz-21" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=1;exitY=0.5;entryX=1;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;exitDx=0;exitDy=0;" target="8hYolZAXGm6dQjdigBHz-17">
            <mxGeometry relative="1" x="-0.0016" as="geometry">
              <Array as="points">
                <mxPoint x="692" y="865.31" />
                <mxPoint x="692" y="312.45" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>

<mxfile host="app.diagrams.net">
  <diagram name="Page-1" id="Rwjd3ovHAP_TvUot5QGn">
    <mxGraphModel dx="2261" dy="825" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="850" pageHeight="1100" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
        <UserObject label="" mermaidData="{&#xa;  &quot;data&quot;: &quot;stateDiagram-v2\n    [*] --&gt; IDLE\n    IDLE --&gt; REQ_ADDR : START=1\n    REQ_ADDR --&gt; WAIT_DATA : ARREADY=1\n    WAIT_DATA --&gt; PUSH_FIFO : RVALID=1\n    PUSH_FIFO --&gt; WAIT_DATA : Burst belum selesai\n    PUSH_FIFO --&gt; REQ_ADDR : 1 dokumen selesai, sisa job &gt; 0\n    PUSH_FIFO --&gt; IDLE : Semua job selesai\n&quot;,&#xa;  &quot;config&quot;: null,&#xa;  &quot;version&quot;: &quot;12&quot;&#xa;}" id="eM2F7Gx6rKrS7lVQNsB9-14">
          <mxCell connectable="0" parent="1" style="group;transparentBounds=1;editIcon=1;lockedGroup=0;groupPadding=10;" vertex="1">
            <mxGeometry as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="" mermaidId="n:root_start" mermaidBaseStyle="ellipse;html=1;fillColor=#000000;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;strokeWidth=1;shadow=1;shadowColor=#000000;shadowOffsetX=2;shadowOffsetY=2;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="" id="eM2F7Gx6rKrS7lVQNsB9-15">
          <mxCell parent="eM2F7Gx6rKrS7lVQNsB9-14" style="ellipse;html=1;fillColor=#000000;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;strokeWidth=1;shadow=1;shadowColor=#000000;shadowOffsetX=2;shadowOffsetY=2;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="14" width="14" x="273" y="30" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="IDLE" mermaidId="n:IDLE" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="IDLE" id="eM2F7Gx6rKrS7lVQNsB9-16">
          <mxCell parent="eM2F7Gx6rKrS7lVQNsB9-14" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="212" y="84" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="REQ_ADDR" mermaidId="n:REQ_ADDR" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="REQ_ADDR" id="eM2F7Gx6rKrS7lVQNsB9-17">
          <mxCell parent="eM2F7Gx6rKrS7lVQNsB9-14" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="138" y="222" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="WAIT_DATA" mermaidId="n:WAIT_DATA" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="WAIT_DATA" id="eM2F7Gx6rKrS7lVQNsB9-18">
          <mxCell parent="eM2F7Gx6rKrS7lVQNsB9-14" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="30" y="361" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="PUSH_FIFO" mermaidId="n:PUSH_FIFO" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="PUSH_FIFO" id="eM2F7Gx6rKrS7lVQNsB9-19">
          <mxCell parent="eM2F7Gx6rKrS7lVQNsB9-14" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="190" y="519" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="" mermaidId="e:root_start-&gt;IDLE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;exitX=0.53;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="" id="eM2F7Gx6rKrS7lVQNsB9-20">
          <mxCell edge="1" parent="eM2F7Gx6rKrS7lVQNsB9-14" source="eM2F7Gx6rKrS7lVQNsB9-15" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;exitX=0.53;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" target="eM2F7Gx6rKrS7lVQNsB9-16">
            <mxGeometry relative="1" as="geometry">
              <Array as="points" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="&lt;span style=&quot;background-color: light-dark(rgb(255, 255, 255), rgb(62, 62, 62));&quot;&gt;START=1&lt;/span&gt;" mermaidId="e:IDLE-&gt;REQ_ADDR#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.36;exitY=1;entryX=0.5;entryY=0.01;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="START=1" id="eM2F7Gx6rKrS7lVQNsB9-21">
          <mxCell edge="1" parent="eM2F7Gx6rKrS7lVQNsB9-14" source="eM2F7Gx6rKrS7lVQNsB9-16" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.36;exitY=1;entryX=0.5;entryY=0.01;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" target="eM2F7Gx6rKrS7lVQNsB9-17">
            <mxGeometry relative="1" as="geometry">
              <Array as="points">
                <mxPoint x="261" y="141" />
                <mxPoint x="206" y="141" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="&lt;span style=&quot;background-color: light-dark(rgb(255, 255, 255), rgb(62, 62, 62));&quot;&gt;ARREADY=1&lt;/span&gt;" mermaidId="e:REQ_ADDR-&gt;WAIT_DATA#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.36;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="ARREADY=1" id="eM2F7Gx6rKrS7lVQNsB9-22">
          <mxCell edge="1" parent="eM2F7Gx6rKrS7lVQNsB9-14" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0;exitY=0.5;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;">
            <mxGeometry relative="1" x="0.2336" as="geometry">
              <mxPoint as="offset" />
              <mxPoint x="138" y="240.5" as="sourcePoint" />
              <mxPoint x="98" y="361" as="targetPoint" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="&lt;span style=&quot;background-color: light-dark(rgb(255, 255, 255), rgb(62, 62, 62));&quot;&gt;RVALID=1&lt;/span&gt;" mermaidId="e:WAIT_DATA-&gt;PUSH_FIFO#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.36;exitY=0.99;entryX=0.24;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="RVALID=1" id="eM2F7Gx6rKrS7lVQNsB9-23">
          <mxCell edge="1" parent="eM2F7Gx6rKrS7lVQNsB9-14" source="eM2F7Gx6rKrS7lVQNsB9-18" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0;exitY=0.5;entryX=0;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;entryDx=0;entryDy=0;" target="eM2F7Gx6rKrS7lVQNsB9-19">
            <mxGeometry relative="1" x="-0.3462" as="geometry">
              <mxPoint as="offset" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="&lt;span style=&quot;background-color: light-dark(rgb(255, 255, 255), rgb(62, 62, 62));&quot;&gt;Burst belum selesai&lt;/span&gt;" mermaidId="e:PUSH_FIFO-&gt;WAIT_DATA#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.41;exitY=0;entryX=0.64;entryY=0.99;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Burst belum selesai" id="eM2F7Gx6rKrS7lVQNsB9-24">
          <mxCell edge="1" parent="eM2F7Gx6rKrS7lVQNsB9-14" source="eM2F7Gx6rKrS7lVQNsB9-19" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.41;exitY=0;entryX=0.5;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;" target="eM2F7Gx6rKrS7lVQNsB9-18">
            <mxGeometry relative="1" x="-0.0699" as="geometry">
              <Array as="points">
                <mxPoint x="245.8" y="479" />
                <mxPoint x="98" y="479" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="&lt;span style=&quot;background-color: light-dark(rgb(255, 255, 255), rgb(62, 62, 62));&quot;&gt;1 dokumen selesai, sisa job &amp;gt; 0&lt;/span&gt;" mermaidId="e:PUSH_FIFO-&gt;REQ_ADDR#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.58;exitY=0;entryX=0.64;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="1 dokumen selesai, sisa job &gt; 0" id="eM2F7Gx6rKrS7lVQNsB9-25">
          <mxCell edge="1" parent="eM2F7Gx6rKrS7lVQNsB9-14" source="eM2F7Gx6rKrS7lVQNsB9-19" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.945;exitY=0.01;entryX=1;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;exitDx=0;exitDy=0;exitPerimeter=0;" target="eM2F7Gx6rKrS7lVQNsB9-17">
            <mxGeometry relative="1" x="-0.0414" as="geometry">
              <Array as="points">
                <mxPoint x="317.2" y="519.4" />
                <mxPoint x="317.2" y="516.2" />
                <mxPoint x="315" y="516.2" />
                <mxPoint x="315" y="240.5" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="&lt;span style=&quot;background-color: light-dark(rgb(255, 255, 255), rgb(62, 62, 62));&quot;&gt;Semua job selesai&lt;/span&gt;" mermaidId="e:PUSH_FIFO-&gt;IDLE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.75;exitY=0;entryX=0.65;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Semua job selesai" id="eM2F7Gx6rKrS7lVQNsB9-26">
          <mxCell edge="1" parent="eM2F7Gx6rKrS7lVQNsB9-14" source="eM2F7Gx6rKrS7lVQNsB9-19" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=1;exitY=0.5;entryX=1;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;exitDx=0;exitDy=0;" target="eM2F7Gx6rKrS7lVQNsB9-16">
            <mxGeometry relative="1" x="0.0231" as="geometry">
              <Array as="points">
                <mxPoint x="444" y="537.5" />
                <mxPoint x="444" y="102.5" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>

<mxfile host="app.diagrams.net">
  <diagram name="Page-1" id="eWOYyLrnYk3ihzcmkBLA">
    <mxGraphModel dx="1016" dy="594" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="850" pageHeight="1100" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
        <UserObject label="" mermaidData="{&#xa;  &quot;data&quot;: &quot;stateDiagram-v2\n    [*] --&gt; WAIT_DATA\n    WAIT_DATA --&gt; ACCUMULATE : TVALID=1\n    ACCUMULATE --&gt; DISPATCH_BLOCK : Terkumpul 1024-bit\n    ACCUMULATE --&gt; PAD_0x80 : TLAST=1 (Akhir Dokumen)\n    DISPATCH_BLOCK --&gt; WAIT_DATA : TREADY=1 (dari Dispatcher)\n    PAD_0x80 --&gt; PAD_ZEROS : Otomatis\n    PAD_ZEROS --&gt; PAD_LENGTH : Ruang sisa &lt; 128-bit\n    PAD_LENGTH --&gt; WAIT_DATA : Kirim blok terakhir\n&quot;,&#xa;  &quot;config&quot;: null,&#xa;  &quot;version&quot;: &quot;12&quot;&#xa;}" id="gZKSW0-F05kimG1mYUTi-1">
          <mxCell connectable="0" parent="1" style="group;transparentBounds=1;editIcon=1;lockedGroup=0;groupPadding=10;labelBackgroundColor=none;" vertex="1">
            <mxGeometry as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="" mermaidId="n:root_start" mermaidBaseStyle="ellipse;html=1;fillColor=#000000;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;strokeWidth=1;shadow=1;shadowColor=#000000;shadowOffsetX=2;shadowOffsetY=2;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="" id="gZKSW0-F05kimG1mYUTi-2">
          <mxCell parent="gZKSW0-F05kimG1mYUTi-1" style="ellipse;html=1;fillColor=#000000;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;strokeWidth=1;shadow=1;shadowColor=#000000;shadowOffsetX=2;shadowOffsetY=2;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="14" width="14" x="403" y="30" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="WAIT_DATA" mermaidId="n:WAIT_DATA" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="WAIT_DATA" id="gZKSW0-F05kimG1mYUTi-3">
          <mxCell parent="gZKSW0-F05kimG1mYUTi-1" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="342" y="84" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="ACCUMULATE" mermaidId="n:ACCUMULATE" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="ACCUMULATE" id="gZKSW0-F05kimG1mYUTi-4">
          <mxCell parent="gZKSW0-F05kimG1mYUTi-1" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="118" y="222" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="DISPATCH_BLOCK" mermaidId="n:DISPATCH_BLOCK" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="DISPATCH_BLOCK" id="gZKSW0-F05kimG1mYUTi-5">
          <mxCell parent="gZKSW0-F05kimG1mYUTi-1" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="260" y="361" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="PAD_0x80" mermaidId="n:PAD_0x80" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="PAD_0x80" id="gZKSW0-F05kimG1mYUTi-6">
          <mxCell parent="gZKSW0-F05kimG1mYUTi-1" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="30" y="361" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="PAD_ZEROS" mermaidId="n:PAD_ZEROS" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="PAD_ZEROS" id="gZKSW0-F05kimG1mYUTi-7">
          <mxCell parent="gZKSW0-F05kimG1mYUTi-1" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="30" y="499" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="PAD_LENGTH" mermaidId="n:PAD_LENGTH" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="PAD_LENGTH" id="gZKSW0-F05kimG1mYUTi-8">
          <mxCell parent="gZKSW0-F05kimG1mYUTi-1" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="287" y="637" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="" mermaidId="e:root_start-&gt;WAIT_DATA#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;exitX=0.52;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="" id="gZKSW0-F05kimG1mYUTi-9">
          <mxCell edge="1" parent="gZKSW0-F05kimG1mYUTi-1" source="gZKSW0-F05kimG1mYUTi-2" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;exitX=0.52;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" target="gZKSW0-F05kimG1mYUTi-3">
            <mxGeometry relative="1" as="geometry">
              <Array as="points" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="TVALID=1" mermaidId="e:WAIT_DATA-&gt;ACCUMULATE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.29;exitY=1;entryX=0.5;entryY=0.01;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="TVALID=1" id="gZKSW0-F05kimG1mYUTi-10">
          <mxCell edge="1" parent="gZKSW0-F05kimG1mYUTi-1" source="gZKSW0-F05kimG1mYUTi-3" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0;exitY=0.5;entryX=0.5;entryY=0.01;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;" target="gZKSW0-F05kimG1mYUTi-4">
            <mxGeometry relative="1" x="0.1604" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Terkumpul 1024-bit" mermaidId="e:ACCUMULATE-&gt;DISPATCH_BLOCK#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.64;exitY=1;entryX=0.36;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Terkumpul 1024-bit" id="gZKSW0-F05kimG1mYUTi-11">
          <mxCell edge="1" parent="gZKSW0-F05kimG1mYUTi-1" source="gZKSW0-F05kimG1mYUTi-4" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=1;exitY=0.5;entryX=0.36;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;" target="gZKSW0-F05kimG1mYUTi-5">
            <mxGeometry relative="1" x="0.4745" as="geometry">
              <Array as="points">
                <mxPoint x="310" y="240.5" />
                <mxPoint x="310" y="280" />
                <mxPoint x="309" y="280" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="TLAST=1 (Akhir Dokumen)" mermaidId="e:ACCUMULATE-&gt;PAD_0x80#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.36;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="TLAST=1 (Akhir Dokumen)" id="gZKSW0-F05kimG1mYUTi-12">
          <mxCell edge="1" parent="gZKSW0-F05kimG1mYUTi-1" source="gZKSW0-F05kimG1mYUTi-4" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0;exitY=0.5;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;" target="gZKSW0-F05kimG1mYUTi-6">
            <mxGeometry relative="1" x="0.2872" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="&lt;span style=&quot;background-color: light-dark(rgb(255, 255, 255), rgb(62, 62, 62));&quot;&gt;TREADY=1 (dari Dispatcher)&lt;/span&gt;" mermaidId="e:DISPATCH_BLOCK-&gt;WAIT_DATA#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.64;exitY=0;entryX=0.5;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="TREADY=1 (dari Dispatcher)" id="gZKSW0-F05kimG1mYUTi-13">
          <mxCell edge="1" parent="gZKSW0-F05kimG1mYUTi-1" source="gZKSW0-F05kimG1mYUTi-5" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=1;exitY=0.5;entryX=0.5;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;" target="gZKSW0-F05kimG1mYUTi-3">
            <mxGeometry relative="1" x="-0.0899" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Otomatis" mermaidId="e:PAD_0x80-&gt;PAD_ZEROS#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=0.99;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Otomatis" id="gZKSW0-F05kimG1mYUTi-14">
          <mxCell edge="1" parent="gZKSW0-F05kimG1mYUTi-1" source="gZKSW0-F05kimG1mYUTi-6" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=0.99;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" target="gZKSW0-F05kimG1mYUTi-7">
            <mxGeometry relative="1" as="geometry">
              <Array as="points" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="Ruang sisa &amp;lt; 128-bit" mermaidId="e:PAD_ZEROS-&gt;PAD_LENGTH#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=1;entryX=0.36;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Ruang sisa &lt; 128-bit" id="gZKSW0-F05kimG1mYUTi-15">
          <mxCell edge="1" parent="gZKSW0-F05kimG1mYUTi-1" source="gZKSW0-F05kimG1mYUTi-7" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=1;entryX=0;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;" target="gZKSW0-F05kimG1mYUTi-8">
            <mxGeometry relative="1" x="0.1021" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Kirim blok terakhir" mermaidId="e:PAD_LENGTH-&gt;WAIT_DATA#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.64;exitY=0;entryX=0.72;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Kirim blok terakhir" id="gZKSW0-F05kimG1mYUTi-16">
          <mxCell edge="1" parent="gZKSW0-F05kimG1mYUTi-1" source="gZKSW0-F05kimG1mYUTi-8" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=1;exitY=0.5;entryX=1;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;exitDx=0;exitDy=0;" target="gZKSW0-F05kimG1mYUTi-3">
            <mxGeometry relative="1" x="-0.0135" as="geometry">
              <Array as="points">
                <mxPoint x="545" y="655.5" />
                <mxPoint x="545" y="102.5" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>

<mxfile host="app.diagrams.net">
  <diagram name="Page-1" id="ZXU4hrvbiTiYAcgek41p">
    <mxGraphModel dx="840" dy="491" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="850" pageHeight="1100" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
        <UserObject label="" mermaidData="{&#xa;  &quot;data&quot;: &quot;stateDiagram-v2\n    [*] --&gt; IDLE\n    IDLE --&gt; CHECK_JOB_ID : Data Valid (1024-bit)\n    CHECK_JOB_ID --&gt; ROUTE_TO_EXISTING : Lanjutan dokumen lama\n    CHECK_JOB_ID --&gt; FIND_FREE_CORE : Dokumen baru\n    FIND_FREE_CORE --&gt; SEND_DATA : Ditemukan Core Idle\n    FIND_FREE_CORE --&gt; FIND_FREE_CORE : Semua Core Sibuk (Stall)\n    ROUTE_TO_EXISTING --&gt; IDLE : Core merespons ready=1\n    SEND_DATA --&gt; IDLE : Core merespons ready=1&quot;,&#xa;  &quot;config&quot;: null,&#xa;  &quot;version&quot;: &quot;12&quot;&#xa;}" id="16">
          <mxCell connectable="0" parent="1" style="group;transparentBounds=1;editIcon=1;lockedGroup=0;groupPadding=10;" vertex="1">
            <mxGeometry as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="" mermaidId="n:root_start" mermaidBaseStyle="ellipse;html=1;fillColor=#000000;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;strokeWidth=1;shadow=1;shadowColor=#000000;shadowOffsetX=2;shadowOffsetY=2;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="" id="2">
          <mxCell parent="16" style="ellipse;html=1;fillColor=#000000;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;strokeWidth=1;shadow=1;shadowColor=#000000;shadowOffsetX=2;shadowOffsetY=2;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="14" width="14" x="562" y="12" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="IDLE" mermaidId="n:IDLE" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="IDLE" id="3">
          <mxCell parent="16" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="501" y="66" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="CHECK_JOB_ID" mermaidId="n:CHECK_JOB_ID" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="CHECK_JOB_ID" id="4">
          <mxCell parent="16" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="284" y="160" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="ROUTE_TO_EXISTING" mermaidId="n:ROUTE_TO_EXISTING" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="ROUTE_TO_EXISTING" id="5">
          <mxCell parent="16" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;labelWidth=120;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="390" y="310" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="FIND_FREE_CORE" mermaidId="n:FIND_FREE_CORE" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="FIND_FREE_CORE" id="6">
          <mxCell parent="16" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="200" y="290" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="SEND_DATA" mermaidId="n:SEND_DATA" mermaidBaseStyle="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;" mermaidBaseValue="SEND_DATA" id="7">
          <mxCell parent="16" style="rounded=1;absoluteArcSize=1;arcSize=10;html=1;whiteSpace=wrap;strokeWidth=2;fillColor=#ffffff;strokeColor=#28253D;fontColor=#28253D;fontFamily=Recursive;fontSize=14;shadow=1;shadowColor=#000000;shadowOffsetX=4;shadowOffsetY=4;shadowBlur=0;shadowOpacity=6;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;" vertex="1">
            <mxGeometry height="37" width="136" x="425" y="481" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="" mermaidId="e:root_start-&gt;IDLE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;exitX=0.51;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="" id="8">
          <mxCell edge="1" parent="16" source="2" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;exitX=0.51;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" target="3">
            <mxGeometry relative="1" as="geometry">
              <Array as="points" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="&lt;span&gt;Data Valid (1024-bit)&lt;/span&gt;" mermaidId="e:IDLE-&gt;CHECK_JOB_ID#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.29;exitY=1;entryX=0.5;entryY=0.01;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Data Valid (1024-bit)" id="9">
          <mxCell edge="1" parent="16" source="3" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0;exitY=0.5;entryX=0.5;entryY=0.01;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;" target="4">
            <mxGeometry relative="1" x="0.1665" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Lanjutan dokumen lama" mermaidId="e:CHECK_JOB_ID-&gt;ROUTE_TO_EXISTING#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.64;exitY=1;entryX=0.36;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Lanjutan dokumen lama" id="10">
          <mxCell edge="1" parent="16" source="4" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=1;exitY=0.5;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;exitDx=0;exitDy=0;" target="5">
            <mxGeometry relative="1" x="0.0316" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Dokumen baru" mermaidId="e:CHECK_JOB_ID-&gt;FIND_FREE_CORE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.36;exitY=1;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Dokumen baru" id="11">
          <mxCell edge="1" parent="16" source="4" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0;exitY=0.5;entryX=0.5;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;" target="6">
            <mxGeometry relative="1" x="0.2532" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Ditemukan Core Idle" mermaidId="e:FIND_FREE_CORE-&gt;SEND_DATA#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=0.99;entryX=0.35;entryY=0;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Ditemukan Core Idle" id="12">
          <mxCell edge="1" parent="16" source="6" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=0.5;exitY=0.99;entryX=0;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;" target="7">
            <mxGeometry relative="1" x="0.0865" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Semua Core Sibuk (Stall)" mermaidId="e:FIND_FREE_CORE-&gt;FIND_FREE_CORE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0;exitY=0.43;entryX=0;entryY=0.55;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Semua Core Sibuk (Stall)" id="13">
          <mxCell edge="1" parent="16" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryX=0;entryY=0.5;entryDx=0;entryDy=0;" target="6">
            <mxGeometry relative="1" x="0.2504" as="geometry">
              <Array as="points">
                <mxPoint x="130" y="390" />
                <mxPoint x="130" y="308.5" />
              </Array>
              <mxPoint x="268" y="390" as="sourcePoint" />
            </mxGeometry>
          </mxCell>
        </UserObject>
        <UserObject label="Core merespons ready=1" mermaidId="e:ROUTE_TO_EXISTING-&gt;IDLE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.64;exitY=0;entryX=0.5;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Core merespons ready=1" id="14">
          <mxCell edge="1" parent="16" source="5" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=1;exitY=0.5;entryX=0.5;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;exitDx=0;exitDy=0;" target="3">
            <mxGeometry relative="1" x="-0.2104" as="geometry" />
          </mxCell>
        </UserObject>
        <UserObject label="Core merespons ready=1" mermaidId="e:SEND_DATA-&gt;IDLE#0" mermaidBaseStyle="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=16;labelBackgroundColor=#cccccc;fontFamily=Recursive;fontColor=#28253D;exitX=0.64;exitY=0;entryX=0.71;entryY=1;strokeWidth=2;targetPerimeterSpacing=3.5;" mermaidBaseValue="Core merespons ready=1" id="15">
          <mxCell edge="1" parent="16" source="7" style="edgeStyle=orthogonalEdgeStyle;rounded=1;curved=0;startArrow=none;endArrow=classic;endSize=5;fillColor=none;jumpStyle=arc;jumpSize=12;strokeColor=#000000;html=1;fontSize=14;labelBackgroundColor=default;fontFamily=Recursive;fontColor=#28253D;exitX=1;exitY=0.5;entryX=1;entryY=0.5;strokeWidth=2;targetPerimeterSpacing=3.5;fontSource=https%3A%2F%2Ffonts.googleapis.com%2Fcss%3Ffamily%3DRecursive;entryDx=0;entryDy=0;exitDx=0;exitDy=0;" target="3">
            <mxGeometry relative="1" x="-0.0193" as="geometry">
              <Array as="points">
                <mxPoint x="676" y="499.5" />
                <mxPoint x="676" y="84.5" />
              </Array>
            </mxGeometry>
          </mxCell>
        </UserObject>
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
titled Diagram5.drawio…]()

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
