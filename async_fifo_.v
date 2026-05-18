//============================================================================
//module top;
//    reg wr_clk, rd_clk;
//    reg wr_en, rd_en;
//    reg [7:0] wr_data;
//    wire full, empty;
//    wire [7:0] rd_data;
//
//    // Instantiate FIFO
//    async_fifo #(
//        .DATA_WIDTH(8),
//        .DEPTH(16)
//    ) u_fifo (
//        .wr_clk  (wr_clk),
//        .wr_en   (wr_en),
//        .wr_data (wr_data),
//        .full    (full),
//        .rd_clk  (rd_clk),
//        .rd_en   (rd_en),
//        .rd_data (rd_data),
//        .empty   (empty)
//    );
//============================================================================
// Key Concepts
// Gray Codes: Binary counters can change multiple bits simultaneously. When crossing clock domains, this can cause "bit skew" where the destination domain sees a corrupted value. Gray codes ensure only one bit changes at a time, making synchronization safe.
// Extra Pointer Bit: The pointers are extended by one bit beyond the address width. This allows the FIFO to distinguish between Full and Empty states (which would otherwise look identical in a standard binary comparison).
// Synchronization Chains: Pointers are converted to Gray, synchronized via dual-flop chains in the target domain, and converted back to binary for comparison.
// Verilog Implementation

module async_fifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH      = 16
)(
    input  wire                    wr_clk,
    input  wire                    wr_en,
    input  wire [DATA_WIDTH-1:0]   wr_data,
    output wire                    full,
    
    input  wire                    rd_clk,
    input  wire                    rd_en,
    output wire [DATA_WIDTH-1:0]   rd_data,
    output wire                    empty
);

    // 1. Calculate Address Width
    // We need clog2(DEPTH) bits for addressing, plus 1 extra bit for full/empty detection
    localparam ADDR_WIDTH = clog2(DEPTH) + 1;
    localparam MEM_DEPTH  = DEPTH;

    // 2. Memory Block
    reg [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

    // 3. Pointers
    // Write pointer (in write domain)
    reg [ADDR_WIDTH-1:0] wr_ptr;
    // Read pointer (in read domain)
    reg [ADDR_WIDTH-1:0] rd_ptr;

    // 4. Gray Code Conversion Functions
    function [ADDR_WIDTH-1:0] bin_to_gray;
        input [ADDR_WIDTH-1:0] bin;
        begin
            bin_to_gray = bin ^ (bin >> 1);
        end
    endfunction

    function [ADDR_WIDTH-1:0] gray_to_bin;
        input [ADDR_WIDTH-1:0] gray;
        reg  [ADDR_WIDTH-1:0] bin;
        integer i;
        begin
            bin = gray;
            for (i = ADDR_WIDTH-1; i > 0; i = i-1) begin
                bin[i-1] = bin[i-1] ^ bin[i];
            end
            gray_to_bin = bin;
        end
    endfunction

    // 5. Pointer Synchronization Logic
    
    // --- Synchronize Write Pointer to Read Domain ---
    wire [ADDR_WIDTH-1:0] wr_ptr_gray;
    assign wr_ptr_gray = bin_to_gray(wr_ptr);
    
    reg [ADDR_WIDTH-1:0] wr_ptr_gray_sync_r1, wr_ptr_gray_sync_r2;
    always @(posedge rd_clk) begin
        wr_ptr_gray_sync_r1 <= wr_ptr_gray;
        wr_ptr_gray_sync_r2 <= wr_ptr_gray_sync_r1;
    end
    
    // Convert synced Gray pointer back to Binary in Read Domain
    reg [ADDR_WIDTH-1:0] wr_ptr_sync_bin;
    always @(posedge rd_clk) begin
        wr_ptr_sync_bin <= gray_to_bin(wr_ptr_gray_sync_r2);
    end

    // --- Synchronize Read Pointer to Write Domain ---
    wire [ADDR_WIDTH-1:0] rd_ptr_gray;
    assign rd_ptr_gray = bin_to_gray(rd_ptr);
    
    reg [ADDR_WIDTH-1:0] rd_ptr_gray_sync_r1, rd_ptr_gray_sync_r2;
    always @(posedge wr_clk) begin
        rd_ptr_gray_sync_r1 <= rd_ptr_gray;
        rd_ptr_gray_sync_r2 <= rd_ptr_gray_sync_r1;
    end
    
    // Convert synced Gray pointer back to Binary in Write Domain
    reg [ADDR_WIDTH-1:0] rd_ptr_sync_bin;
    always @(posedge wr_clk) begin
        rd_ptr_sync_bin <= gray_to_bin(rd_ptr_gray_sync_r2);
    end

    // 6. Write Logic
    always @(posedge wr_clk) begin
        if (wr_en && !full) begin
            mem[wr_ptr[ADDR_WIDTH-2:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1;
        end
    end

    // 7. Read Logic
    always @(posedge rd_clk) begin
        if (rd_en && !empty) begin
            rd_data <= mem[rd_ptr[ADDR_WIDTH-2:0]];
            rd_ptr <= rd_ptr + 1;
        end
    end

    // 8. Full / Empty Detection
    // Empty: Read pointer catches up to Write pointer
    assign empty = (rd_ptr == wr_ptr_sync_bin);
    
    // Full: Write pointer catches up to Read pointer + Depth
    // The extra MSB allows us to detect when the pointer has wrapped around
    assign full = (wr_ptr == rd_ptr_sync_bin + MEM_DEPTH);

    // Helper function for synthesis tools
    function integer clog2;
        input integer depth;
        begin
            depth = depth - 1;
            for (clog2 = 0; depth > 0; clog2 = clog2 + 1)
                depth = depth >> 1;
        end
    endfunction

endmodule



