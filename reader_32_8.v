`timescale 1ns / 1ps

module reader_32_8 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] fifo_data,
    input  wire        fifo_empty,
    output reg         fifo_rd_en,
    input  wire        uart_tx_ready,
    output reg [7:0]   uart_tx_data,
    output reg         uart_tx_valid
);

    localparam S_IDLE      = 3'b000;
    localparam S_LOAD      = 3'b001;
    localparam S_SEND_0    = 3'b010;//(LSB)
    localparam S_SEND_1    = 3'b011;
    localparam S_SEND_2    = 3'b100;
    localparam S_SEND_3    = 3'b101;//(MSB)

    reg [2:0] state_reg;
    reg [2:0] state_next;
    reg [31:0] data_reg;

    always @(*) begin
        state_next = state_reg;

        case (state_reg)
            S_IDLE: begin

                if (!fifo_empty && uart_tx_ready)
                    state_next = S_LOAD;
            end
            S_LOAD: begin
                state_next = S_SEND_0;
            end
            S_SEND_0: begin
                if (uart_tx_ready) state_next = S_SEND_1;
            end
            S_SEND_1: begin
                if (uart_tx_ready) state_next = S_SEND_2;
            end
            S_SEND_2: begin
                if (uart_tx_ready) state_next = S_SEND_3;
            end
            S_SEND_3: begin
                if (uart_tx_ready) state_next = S_IDLE;
            end

            default: begin
                state_next = S_IDLE;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= S_IDLE;
        end else begin
            state_reg <= state_next;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_reg <= 32'b0;
        end else if (state_reg == S_LOAD) begin
            data_reg <= fifo_data;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_rd_en    <= 1'b0;
            uart_tx_valid <= 1'b0;
            uart_tx_data  <= 8'b0;
        end else begin
            fifo_rd_en    <= (state_reg == S_LOAD) ? 1'b1 : 1'b0;
            uart_tx_valid <= (state_reg >= S_SEND_0) ? 1'b1 : 1'b0;
            case (state_reg)
                S_SEND_0: uart_tx_data <= data_reg[7:0];   // LSB
                S_SEND_1: uart_tx_data <= data_reg[15:8];
                S_SEND_2: uart_tx_data <= data_reg[23:16];
                S_SEND_3: uart_tx_data <= data_reg[31:24]; // MSB
                default:  uart_tx_data <= 8'b0;
            endcase
        end
    end

endmodule
