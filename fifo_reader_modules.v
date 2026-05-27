//////////////////////////////////////
`timescale 1ns / 1ps

module fifo_read #(
    parameter DATA_WIDTH = 8   
)(
    input  wire                      clk          
    input  wire                      rst_n        
    input  wire                      fifo_empty   
    input  wire  [DATA_WIDTH-1:0]    fifo_data    
    output reg                       fifo_rd_en   
    input  wire                      uart_tx_ready
    output reg   [DATA_WIDTH-1:0]    uart_tx_data 
    output reg                       uart_tx_wr_en
);

    reg data_valid;

    fifo_rd_en <= ~fifo_empty & ~data_valid;

    always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        data_valid    <= 1'b0;
        uart_tx_data  <= {DATA_WIDTH{1'b0}};
        uart_tx_wr_en <= 1'b0;
      end else begin
        uart_tx_wr_en <= 1'b0;

        if (fifo_rd_en) begin
          uart_tx_data <= fifo_data;
          data_valid   <= 1'b1;
        end

        else if (uart_tx_ready & data_valid) begin
          uart_tx_wr_en <= 1'b1;
          data_valid    <= 1'b0;
        end
      end
    end

endmodule

//////////////////////////////////////
`timescale 1ns / 1ps

module fifo_read_fsm (
  input  wire        clk          ,
  input  wire        rst          ,
  input  wire [7:0]  fifo_data    ,
  input  wire        fifo_empty   ,
  output reg         fifo_rd_en   ,
  input  wire        uart_tx_ready,
  output reg [7:0]   uart_tx_data ,
  output reg         uart_tx_valid
);
//////////////////////////////////////
//////////////////////////////////////
  localparam [1:0] 
    S_IDLE      = 2'b00,
    S_READ_FIFO = 2'b01,
    S_SEND_UART = 2'b10;

  reg [1:0] state_reg, state_next;
  reg [7:0] data_reg;

  always @(*) begin
    state_next = state_reg;
    case (state_reg)
      S_IDLE: begin
        
        if (!fifo_empty && uart_tx_ready)
            state_next = S_READ_FIFO;
        else
            state_next = S_IDLE;
      end
      S_READ_FIFO: begin
        
        state_next = S_SEND_UART;
      end
      S_SEND_UART: begin
        
        state_next = S_IDLE;
      end
      default: begin
        state_next = S_IDLE;
      end
    endcase
  end

  always @(posedge clk) begin
    state_reg <= (rst)? S_IDLE : state_next;
  end

  always @(posedge clk) begin
    if (rst) begin
      data_reg <= 8'b0;
    end else if (state_reg == S_READ_FIFO) begin
      data_reg <= fifo_data;
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      fifo_rd_en    <= 1'b0;
      uart_tx_valid <= 1'b0;
      uart_tx_data  <= 8'b0;
    end else begin
      
      fifo_rd_en    <= (state_reg == S_READ_FIFO) ? 1'b1 : 1'b0;
      
      uart_tx_valid <= (state_reg == S_SEND_UART) ? 1'b1 : 1'b0;
      uart_tx_data  <= data_reg;
    end
  end

endmodule
//////////////////////////////////////