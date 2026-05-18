//============================================================================
// Module: cdc_fifo
// Description: Asynchronous FIFO (A-FIFO) handling Clock Domain Crossing (CDC).
module cdc_fifo #(
    parameter DATA_WIDTH = 32, // Width of the data bus
    parameter DEPTH      = 1024 // Must be a power of 2. Depth = 2^N
) (
    // Global Signals
    input wire clk_src,     // Source Clock Domain (Write side)
    input wire clk_dest,    // Destination Clock Domain (Read side)
    input wire rst          // Reset

    // Write Port (Source Domain: CLK_SRC)
    // The write pointer and full logic run in the source clock domain.
    input wire wr_en_src,   // Write enable signal from Source Domain
    input wire [DATA_WIDTH-1:0] data_in_src, // Data to be written
    output wire fifo_full_src, // Status flag (synchronized to destination)

    // Read Port (Destination Domain: CLK_DEST)
    // The read pointer and empty logic run in the destination clock domain.
    input wire rd_en_dest,  // Read enable signal from Destination Domain
    output wire [DATA_WIDTH-1:0] data_out_dest, // Data read out
    output wire fifo_empty_dest // Status flag (synchronized to source)
);

    // ==============================
    // 1. Internal Memory and Pointers
    // ==============================

    // The actual FIFO memory array
    reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];

    // Write Pointers and Read Pointers (Stored in the respective clock domains)
    reg [$clog2(DEPTH):0] wr_ptr_src; // Source domain pointer
    reg [$clog2(DEPTH):0] rd_ptr_dest; // Destination domain pointer


    // ==============================
    // 2. Synchronization Logic (The CDC Core)
    // ==============================

    // --- A. Synchronizing the Write Pointer to CLK_DEST Domain ---
    // The reader needs to know if the writer has reached capacity.
    reg sync_wr_ptr_q1, sync_wr_ptr_q2;
    always @(posedge clk_dest or posedge rst) begin
        if (rst) begin
            sync_wr_ptr_q1 <= 0;
            sync_wr_ptr_q2 <= 0;
        end else begin
            // Metastability mitigation using two flip-flops
            {sync_wr_ptr_q1, sync_wr_ptr_q2} <= {wr_ptr_src, 1'b0}; // Only pass the low bits for simplicity
        end
    end

    wire wr_ptr_sync = sync_wr_ptr_q2;


    // --- B. Synchronizing the Read Pointer to CLK_SRC Domain ---
    // The writer needs to know if the reader has consumed data.
    reg sync_rd_ptr_q1, sync_rd_ptr_q2;
    always @(posedge clk_src or posedge rst) begin
        if (rst) begin
            sync_rd_ptr_q1 <= 0;
            sync_rd_ptr_q2 <= 0;
        end else begin
             // Metastability mitigation using two flip-flops
            {sync_rd_ptr_q1, sync_rd_ptr_q2} <= {rd_ptr_dest, 1'b0};
        end
    end

    wire rd_ptr_sync = sync_rd_ptr_q2;


    // ==============================
    // 3. Write Side Logic (CLK_SRC Domain)
    // ==============================

    always @(posedge clk_src or posedge rst) begin
        if (rst) begin
            wr_ptr_src <= 0;
        end else if (wr_en_src && !fifo_full_src) begin
             // Check against the synchronized read pointer to ensure space is available
            wr_ptr_src <= wr_ptr_src + 1'b1;
        end
    end

    // Determine Full Status in Source Domain (Source knows when it hits capacity)
    assign fifo_full_src = (wr_ptr_src == rd_ptr_sync);


    // Write Data to Memory
    always @(posedge clk_src or posedge rst) begin
        if (rst) begin
            $display("Reset");
        end else if (wr_en_src && !fifo_full_src) begin
            ram[wr_ptr_src] <= data_in_src;
        end
    end


    // ==============================
    // 4. Read Side Logic (CLK_DEST Domain)
    // ==============================

    always @(posedge clk_dest or posedge rst) begin
        if (rst) begin
            rd_ptr_dest <= 0;
        end else if (rd_en_dest && !fifo_empty_dest) begin
             // Check against the synchronized write pointer to ensure data is available
            rd_ptr_dest <= rd_ptr_dest + 1'b1;
        end
    end

    // Determine Empty Status in Destination Domain (Dest knows when it runs out of data)
    assign fifo_empty_dest = (wr_ptr_sync == rd_ptr_dest);


    // Read Data from Memory
    always @(posedge clk_dest or posedge rst) begin
        if (rst) begin
            $display("Reset");
        end else if (rd_en_dest && !fifo_empty_dest) begin
             data_out_dest <= ram[rd_ptr_dest];
        end
    end

endmodule
