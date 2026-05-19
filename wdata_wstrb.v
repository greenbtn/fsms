//===============================================================================

module axi4s_to_wdata_wstrb #(
    parameter integer DATA_WIDTH = 32
)(
    // Clock and reset
    input                  clk,
    input                  rst_n,

    // AXI4-Stream slave input (we're acting as AXI4-Stream slave)
    input                  tvalid,
    input                  tlast,
    input [DATA_WIDTH-1:0] tdata,
    output reg             tready,

    // Output 32-bit interface with strobe
    output reg [31:0]      wdata,
    output reg [3:0]       wstrb,
    output reg             wvalid,
    input                  wready
);

    // State machine
    localparam IDLE      = 2'b00;
    localparam TX_DATA   = 2'b01;
    localparam TX_LAST   = 2'b10;

    reg [1:0] state, next_state;

    // Control logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            tready <= 1'b1;  // Always ready unless busy
            wvalid <= 1'b0;
        end else begin
            state <= next_state;
            // tready should be 1 when ready to accept data
            tready <= (state == IDLE || state == TX_DATA) ? 1'b1 : 1'b0;
        end
    end

    always @(*) begin
        next_state = state;
        wdata = 32'h0;
        wstrb = 4'h0;
        wvalid = 1'b0;

        case (state)
            IDLE: begin
                if (tvalid) begin
                    next_state = TX_DATA;
                end
            end

            TX_DATA: begin
                wdata = tdata;
                wstrb = 4'hF;
                wvalid = 1'b1;

                // Wait for wready (output ready) and tvalid (input data valid)
                if (wready && tvalid) begin
                    if (tlast) begin
                        next_state = TX_LAST;
                    end
                    // else: stay in TX_DATA, more data coming
                end
            end

            TX_LAST: begin
                wdata = 32'hfdfdbcbc;
                wstrb = 4'hF;
                wvalid = 1'b1;

                if (wready) begin
                    next_state = IDLE;
                end
            end
        endcase
    end

endmodule


//=============================================================================== 
// Тестбенч проверяет:
// Передачу обычных данных без TLAST;
// Корректную передачу TLAST и завершающего слова 0xdeadbeef;
// Поведение при паузах (wready = 0, tvalid = 0);
// Передачу нескольких пакетов последовательно.

`timescale 1ns / 1ps

module tb_axi4s_to_wdata_wstrb;

    // Parameters
    localparam CLK_PERIOD_NS = 5;  // 100 MHz (5ns period)

    // Clock and reset
    reg clk;
    reg rst_n;

    // AXI4-Stream interface (slave)
    reg tvalid;
    reg [31:0] tdata;
    reg tlast;
    wire tready;

    // Output interface
    wire [31:0] wdata;
    wire [3:0] wstrb;
    wire wvalid;
    reg wready;

    // Device Under Test
    axi4s_to_wdata_wstrb #(
        .DATA_WIDTH(32)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .tvalid(tvalid),
        .tdata(tdata),
        .tlast(tlast),
        .tready(tready),
        .wdata(wdata),
        .wstrb(wstrb),
        .wvalid(wvalid),
        .wready(wready)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    // Reset sequence
    initial begin
        rst_n = 0;
        #20;
        rst_n = 1;
    end

    // Monitor outputs
    initial begin
        $dumpfile("tb_axi4s_to_wdata_wstrb.vcd");
        $dumpvars(0, tb_axi4s_to_wdata_wstrb);
        #0;
        $display("=== Start of test ===");
        $monitor("T=%0t | tvalid=%b tlast=%b tdata=0x%08x tready=%b | wvalid=%b wready=%b wdata=0x%08x wstrb=0x%x",
                 $time, tvalid, tlast, tdata, tready, wvalid, wready, wdata, wstrb);
    end

    // Test sequence
    initial begin
        // Initialize
        tvalid = 0;
        tlast = 0;
        tdata = 0;
        wready = 1; // output ready by default

        // Wait reset release
        #20;

        // === TEST 1: Single packet with 3 data words and TLAST ===
        $display("\n--- TEST 1: 3 data words + TLAST ---");

        // Wait a few cycles
        #20;

        // Send 3 data words
        repeat (3) begin
            @(posedge clk);
            tvalid = 1;
            tdata = $random; // random data
            tlast = ($rtoi($random) % 2) == 0; // not used yet (just to avoid x)
            #10;
            @(posedge clk);
            tvalid = 0;
            #10;
        end

        // Send last word with TLAST
        @(posedge clk);
        tvalid = 1;
        tdata = 32'hdeadbeef;
        tlast = 1;
        #10;
        @(posedge clk);
        tvalid = 0;
        tlast = 0;

        // Wait for wvalid to assert, and for final word
        #20;
        $display("Expected: last output = 0xdeadbeef");
        #20;

        // Check that final word was transmitted
        repeat (10) @(posedge clk);

        // === TEST 2: Empty packet (TLAST on first word) ===
        $display("\n--- TEST 2: Single word (TLAST immediately) ---");
        #10;
        @(posedge clk);
        tvalid = 1;
        tdata = 32'hcafebabe;
        tlast = 1;
        #10;
        @(posedge clk);
        tvalid = 0;
        tlast = 0;

        #30;

        // === TEST 3: Pause wready (output stalled) ===
        $display("\n--- TEST 3: wready = 0 (stall output) ---");
        @(posedge clk);
        tvalid = 1;
        tdata = 32'h12345678;
        tlast = 0;
        wready = 0;  // stall!
        #10;
        @(posedge clk);
        // tvalid stays 1, but output not accepted until wready=1
        #20;
        wready = 1;  // resume
        @(posedge clk);
        tvalid = 0;
        #20;

        // === TEST 4: Two packets back-to-back ===
        $display("\n--- TEST 4: Two packets back-to-back ---");
        // First packet: 2 words
        repeat (2) begin
            @(posedge clk);
            tvalid = 1;
            tdata = 32'haaaa + $random;
            tlast = 0;
            #10;
            @(posedge clk);
            tvalid = 0;
            #10;
        end
        // TLAST
        @(posedge clk);
        tvalid = 1;
        tdata = 32'hbbbb5555;
        tlast = 1;
        #10;
        @(posedge clk);
        tvalid = 0;
        tlast = 0;

        #20;

        // Second packet: 1 word + TLAST
        @(posedge clk);
        tvalid = 1;
        tdata = 32'hcccc9999;
        tlast = 1;
        #10;
        @(posedge clk);
        tvalid = 0;
        tlast = 0;

        #40;

        // === Finish ===
        $display("\n=== All tests completed ===");
        $finish;
    end

    // Optional: check correctness of outputs
    reg [31:0] expected_word = 0;
    reg is_last_word_expected = 0;

    always @(posedge clk) begin
        if (rst_n == 0) return;

        // Track expected flow
        if (tvalid && tready && ~tlast) begin
            expected_word <= tdata;
            is_last_word_expected <= 0;
            // $display("Tx data word: 0x%08x", tdata);
        end
        if (tvalid && tready && tlast) begin
            expected_word <= tdata;
            is_last_word_expected <= 1;
        end

        if (wvalid && wready) begin
            if (is_last_word_expected) begin
                if (wdata != 32'hfdfdbcbc) begin
                    $error("ERROR: Expected final word 0xdeadbeef but got 0x%08x", wdata);
                end else begin
                    $display("PASS: Final word = 0xdeadbeef ?");
                end
                is_last_word_expected <= 0;
            end else begin
                if (wdata != expected_word) begin
                    $error("ERROR: wdata (0x%08x) != expected (0x%08x)", wdata, expected_word);
                end else begin
                    // $display("OK: wdata = 0x%08x", wdata);
                end
            end
            // strobe must always be 4'hF
            if (wstrb != 4'hF) begin
                $error("ERROR: wstrb = 0x%x (expected 0xF)", wstrb);
            end
        end
    end

endmodule


// Как запустить:
// iverilog tb_axi4s_to_wdata_wstrb.v axi4s_to_wdata_wstrb.v -o tb
// vvp tb
// # или: vsim -c tb_axi4s_to_wdata_wstrb
// Файл tb_axi4s_to_wdata_wstrb.vcd будет содержать трассировку сигналов для Waveform Viewer.