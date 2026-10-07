# SHA-512 Accelerator System Operation

The SHA-512 accelerator operates through a coordinated hardware-software pipeline on the DE10-Nano platform to verify e-Meterai and Peruri Sign documents. The system distributes workloads across four functional planes to offload cryptographic hashing from the host CPU (ARM processor) to the FPGA fabric.

## 1. Document Preparation (Software Plane)
The operation begins in the user-space of the host ARM processor.
* **Ingestion and Parsing:** The software application receives a PDF document and passes it to a dedicated library (`libsha512.so`). The library parses the PDF structure to locate the `/ByteRange` and `/Contents` sections.
* **Hash Extraction:** The library extracts the X.509 certificate from the PKCS#7 signature block to retrieve the expected SHA-512 hash.
* **Job Submission:** The software writes the document's signed byte range to the kernel driver (`/dev/sha512`). The driver maps this data to a DMA (Direct Memory Access) buffer in the HPS DDR3 memory, assigns a unique Job ID, and programs the PL330 DMA engine to handle the transfer.

## 2. Data Ingestion (Interface Plane)
The Interface Plane moves data across the boundary between the host processor and the FPGA without active CPU intervention.
* **HPS to FPGA Transfer:** The PL330 DMA engine reads the document from DDR3 memory and writes it to the FPGA via the 64-bit **h2f (HPS-to-FPGA) bridge**.
* **Buffering and Conversion:** Data enters the Input FIFO, which bridges the memory-mapped AXI3 protocol from the host to the streaming AXI4-Stream protocol required by the hashing cores. The FIFO also handles clock domain crossing from the bridge clock to the core hardware clock.

## 3. Cryptographic Computation (Implementation Plane)
Once data streams into the FPGA fabric, the dedicated hardware takes over the sequential processing.
* **Block Splitting:** The incoming 64-bit stream is padded according to SHA-512 standards (appending a '1' bit, necessary '0' bits, and the original message length) and assembled into 1024-bit blocks.
* **Work Dispatching:** A Dispatcher evaluates the status of the available SHA-512 processing cores. Because SHA-512 is sequential within a single document, all blocks of the same document (identified by the Job ID) are routed to the same core. New documents are assigned to the first available idle core.
* **Hashing:** The assigned core computes the hash by executing a 64-cycle message schedule and 80 compression rounds. This results in a 512-bit digest.
* **Result Aggregation:** The Result Aggregator collects completed digests from the core array, tags them with their corresponding Job ID, and queues them for output.

## 4. Status and Coordination (Control FSM Plane)
Operating in parallel to the data stream, the Control FSM Plane manages system state and hardware telemetry.
* **Configuration:** The driver configures the system via the lightweight **lwh2f bridge**, accessing memory-mapped registers to enable specific cores, set job parameters, and trigger the start command.
* **Clock Gating:** A Core Manager automatically gates the clock and holds disabled cores in reset to conserve power.
* **Interrupt Generation:** Once the Result Aggregator confirms a job is complete, the Interrupt Controller generates an IRQ (interrupt request) sent directly to the host's Generic Interrupt Controller (GIC).

## 5. Result Return and Verification
The final phase returns the hardware-computed hash back to the software for comparison.
* **FPGA to HPS Transfer:** The Output FIFO passes the 512-bit digest and Job ID to an AXI3 Master FSM, which divides the data into 64-bit segments. These segments are written directly back to the HPS DDR3 memory via the **f2h bridge**.
* **Interrupt Handling:** The generated IRQ wakes the kernel driver, which reads the completion status and invalidates the CPU cache to safely read the new DMA memory.
* **Final Verdict:** The computed hash is passed back to the user-space library, which compares it against the previously extracted expected hash from the X.509 certificate. The application then reports the document as authentic or tampered based on this final comparison.