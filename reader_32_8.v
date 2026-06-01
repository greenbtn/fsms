`timescale 1ns / 1ps

module mod_32_8 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] fifo_data,
    input  wire        fifo_empty,
    output reg         fifo_rd_en,
    input  wire        uart_tx_ready,
    output reg [7:0]   uart_tx_data,
    output reg         uart_tx_valid
);

    localparam S_IDLE       = 3'b000;
    localparam S_GET_WORD   = 3'b001;
    localparam S_SEND_BYTE0 = 3'b010;
    localparam S_SEND_BYTE1 = 3'b011;
    localparam S_SEND_BYTE2 = 3'b100;
    localparam S_SEND_BYTE3 = 3'b101;
    localparam S_IS_EMPTY   = 3'b110;
    localparam S_READ_FIFO  = 3'b111;

    reg [2:0] state_reg;
    reg [2:0] state_next;
    reg [31:0] data_reg;

    always @(*) begin
        state_next = state_reg;

        case (state_reg)
            S_IDLE: begin
                if (!fifo_empty && uart_tx_ready)
                    state_next = S_GET_WORD;
            end
            S_GET_WORD: begin
                state_next = S_SEND_BYTE0;
            end

            S_SEND_BYTE0: begin
                if (uart_tx_ready) state_next = S_SEND_BYTE1;
            end

            S_SEND_BYTE1: begin
                if (uart_tx_ready) state_next = S_SEND_BYTE2;
            end

            S_SEND_BYTE2: begin
                if (uart_tx_ready) state_next = S_SEND_BYTE3;
            end

            S_SEND_BYTE3: begin
                if (uart_tx_ready) state_next = S_IS_EMPTY;
            end

            S_IS_EMPTY: begin
                
                if (fifo_empty) state_next = S_IDLE;
                else           state_next = S_READ_FIFO;
            end

            S_READ_FIFO: begin
                
                state_next = S_GET_WORD;
            end

            default: begin
                state_next = S_IDLE;
            end
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state_reg <= S_IDLE;
        end else begin
            state_reg <= state_next;
        end
    end


    always @(posedge clk) begin
        if (!rst_n) begin
            data_reg <= 32'b0;
        end else if (state_reg == S_GET_WORD) begin
            data_reg <= fifo_data;
        end
    end


    always @(posedge clk) begin
        if (!rst_n) begin
            fifo_rd_en    <= 1'b0;
            uart_tx_valid <= 1'b0;
            uart_tx_data  <= 8'b0;
        end else begin
            fifo_rd_en    <= (state_reg == S_READ_FIFO) ? 1'b1 : 1'b0;
            uart_tx_valid <= (state_reg == S_SEND_BYTE0) ||
                            (state_reg == S_SEND_BYTE1) ||
                            (state_reg == S_SEND_BYTE2) ||
                            (state_reg == S_SEND_BYTE3);
            
            case (state_reg)
                S_SEND_BYTE0: uart_tx_data <= data_reg[7:0];   // LSB
                S_SEND_BYTE1: uart_tx_data <= data_reg[15:8];
                S_SEND_BYTE2: uart_tx_data <= data_reg[23:16];
                S_SEND_BYTE3: uart_tx_data <= data_reg[31:24]; // MSB
                default:      uart_tx_data <= 8'b0;
            endcase
        end
    end

endmodule

////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module mod_32_8_opt (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] fifo_data,
    input  wire        fifo_empty,
    output reg         fifo_rd_en,
    input  wire        uart_tx_ready,
    output reg [7:0]   uart_tx_data,
    output reg         uart_tx_valid
);


    localparam S_IDLE       = 3'b000;
    localparam S_GET_WORD   = 3'b001;
    localparam S_SEND_BYTE0 = 3'b010;
    localparam S_SEND_BYTE1 = 3'b011;
    localparam S_SEND_BYTE2 = 3'b100;
    localparam S_SEND_BYTE3 = 3'b101;
    localparam S_IS_EMPTY   = 3'b110;
    localparam S_READ_FIFO  = 3'b111;

    reg [2:0] state_reg;
    reg [2:0] state_next;
    reg [31:0] data_reg;


    always @(*) begin
        state_next = state_reg;

        case (state_reg)
            S_IDLE: begin
                if (!fifo_empty && uart_tx_ready)
                    state_next = S_GET_WORD;
            end

            S_GET_WORD: begin
                state_next = S_SEND_BYTE0;
            end

            S_SEND_BYTE0: if (uart_tx_ready) state_next = S_SEND_BYTE1;
            S_SEND_BYTE1: if (uart_tx_ready) state_next = S_SEND_BYTE2;
            S_SEND_BYTE2: if (uart_tx_ready) state_next = S_SEND_BYTE3;
            S_SEND_BYTE3: if (uart_tx_ready) state_next = S_IS_EMPTY;

            S_IS_EMPTY: begin
                state_next = fifo_empty ? S_IDLE : S_READ_FIFO;
            end

            S_READ_FIFO: begin
                state_next = S_GET_WORD;
            end

            default: state_next = S_IDLE;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) state_reg <= S_IDLE;
        else       state_reg <= state_next;
    end


    always @(posedge clk) begin
        if (!rst_n) data_reg <= 32'b0;
        else if (state_reg == S_GET_WORD) data_reg <= fifo_data;
    end


    always @(posedge clk) begin
        if (!rst_n) begin
            fifo_rd_en    <= 1'b0;
            uart_tx_valid <= 1'b0;
            uart_tx_data  <= 8'b0;
        end else begin
           
            fifo_rd_en <= (state_reg == S_READ_FIFO);

           
            uart_tx_valid <= (state_reg >= S_SEND_BYTE0 && state_reg <= S_SEND_BYTE3);

            
            case (state_reg)
                S_SEND_BYTE0: uart_tx_data <= data_reg[7:0];
                S_SEND_BYTE1: uart_tx_data <= data_reg[15:8];
                S_SEND_BYTE2: uart_tx_data <= data_reg[23:16];
                S_SEND_BYTE3: uart_tx_data <= data_reg[31:24];
                default:      uart_tx_data <= 8'b0;
            endcase
        end
    end

endmodule

