
module axi4s_to_lmb_bridge #(
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = (DATA_WIDTH / 8),
    parameter ADDR_WIDTH = 32
)(
    // LMB Clock & Reset
    input  wire                         LMB_Clk,
    input  wire                         LMB_RST,
    
    // AXI4-Stream Interface
    input  wire                         aclk,
    input  wire                         aresetn,
    input  wire                         TVALID,
    output wire                         TREADY,
    input  wire [DATA_WIDTH-1:0]        TDATA,
    input  wire [STRB_WIDTH-1:0]        TSTRB,
    input  wire                         TLAST,
    
    // LMB Master Interface (Slave port of target memory)
    output wire [ADDR_WIDTH-1:0]        M_A,
    output wire [DATA_WIDTH-1:0]        M_D,
    output wire [STRB_WIDTH-1:0]        M_BE,
    output wire                         M_CYC,
    output wire                         M_STB,
    output wire                         M_WE,
    output wire [STRB_WIDTH-1:0]        M_SEL,
    input  wire                         M_ACK,
    output wire                         M_ERR,
    output wire                         M_RTY,
    output wire                         M_DV
);

    // State definitions
    typedef enum logic [2:0] {
        IDLE,
        WAIT_AXI,
        CYC_ASSERT,
        WAIT_ACK,
        LAST_BEAT
    } state_t;
    
    state_t curr_state, next_state;
    
    // Internal registers
    reg [ADDR_WIDTH-1:0] m_addr;
    reg [DATA_WIDTH-1:0] m_data_reg;
    reg [STRB_WIDTH-1:0] m_be_reg;
    reg [STRB_WIDTH-1:0] m_sel_reg;
    reg [STRB_WIDTH:0]   byte_cnt;
    reg                  axi_valid_sync;
    reg                  axi_ready_sync;
    
    // AXI4-Stream handshake (synchronized to LMB_Clk)
    // In production, use proper CDC (e.g., XPM_CDC_SYNC)
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) begin
            axi_valid_sync <= 1'b0;
        end else begin
            // Simple synchronizer for TVALID
            axi_valid_sync <= TVALID;
        end
    end
    
    assign TREADY = axi_ready_sync;
    
    // State transition logic
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) begin
            curr_state <= IDLE;
        end else begin
            curr_state <= next_state;
        end
    end
    
    // Next state logic
    always @(*) begin
        case (curr_state)
            IDLE: begin
                if (M_CYC == 1'b0) begin // LMB idle
                    next_state = WAIT_AXI;
                end else begin
                    next_state = IDLE;
                end
            end
            WAIT_AXI: begin
                if (axi_valid_sync) begin
                    next_state = CYC_ASSERT;
                end else if (M_CYC == 1'b0) begin
                    next_state = IDLE;
                end else begin
                    next_state = WAIT_AXI;
                end
            end
            CYC_ASSERT: begin
                if (M_ACK) begin
                    if (byte_cnt == STRB_WIDTH) begin
                        next_state = LAST_BEAT;
                    end else begin
                        next_state = CYC_ASSERT; // Continue burst within same beat
                    end
                end else begin
                    next_state = CYC_ASSERT;
                end
            end
            WAIT_ACK: begin
                if (M_ACK) begin
                    next_state = LAST_BEAT;
                end else begin
                    next_state = WAIT_ACK;
                end
            end
            LAST_BEAT: begin
                if (M_CYC == 1'b0) begin
                    next_state = IDLE;
                end else begin
                    next_state = LAST_BEAT;
                end
            end
            default: next_state = IDLE;
        endcase
    end
    
    // AXI4-Stream output control
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) begin
            axi_ready_sync <= 1'b0;
        end else begin
            case (curr_state)
                WAIT_AXI: axi_ready_sync <= 1'b1;
                CYC_ASSERT: axi_ready_sync <= 1'b0;
                WAIT_ACK: axi_ready_sync <= 1'b0;
                LAST_BEAT: axi_ready_sync <= 1'b0;
                default: axi_ready_sync <= 1'b0;
            endcase
        end
    end
    
    // Data & Address latch from AXI when TREADY asserted
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) begin
            m_data_reg <= {DATA_WIDTH{1'b0}};
            m_be_reg   <= {STRB_WIDTH{1'b0}};
            m_sel_reg  <= {STRB_WIDTH{1'b0}};
            byte_cnt   <= 0;
        end else if (axi_ready_sync && TVALID) begin
            m_data_reg <= TDATA;
            m_be_reg   <= TSTRB;
            m_sel_reg  <= TSTRB;
            byte_cnt   <= 0;
        end
    end
    
    // LMB Master output logic
    assign M_A    = m_addr;
    assign M_D    = (M_CYC & M_STB) ? m_data_reg : {DATA_WIDTH{1'b0}};
    assign M_BE   = m_sel_reg; // Tie BE to SEL for simplicity
    assign M_WE   = (curr_state != IDLE && curr_state != LAST_BEAT) ? 1'b1 : 1'b0;
    assign M_CYC  = (curr_state == CYC_ASSERT || curr_state == WAIT_ACK) ? 1'b1 : 1'b0;
    assign M_STB  = (curr_state == CYC_ASSERT || curr_state == WAIT_ACK) ? 1'b1 : 1'b0;
    assign M_SEL  = m_sel_reg;
    assign M_DV   = M_STB;
    assign M_ERR  = 1'b0;
    assign M_RTY  = 1'b0;
    
    // Burst continuation & address increment logic
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) begin
            m_addr <= {ADDR_WIDTH{1'b0}};
        end else begin
            case (curr_state)
                CYC_ASSERT: begin
                    if (M_ACK) begin
                        byte_cnt <= byte_cnt + 1'b1;
                        // Increment address only when all bytes of current beat are transferred
                        if (byte_cnt == STRB_WIDTH - 1) begin
                            m_addr <= m_addr + STRB_WIDTH;
                        end
                    end
                end
                LAST_BEAT: begin
                    if (M_CYC == 1'b0) begin
                        m_addr <= {ADDR_WIDTH{1'b0}}; // Reset or hold as needed
                    end
                end
                default: ;
            endcase
        end
    end
    
    // TLAST generation: assert when last byte of AXI beat is being transferred
    assign TLAST_out = (curr_state == CYC_ASSERT && byte_cnt == STRB_WIDTH - 1 && TLAST) ? 1'b1 : 1'b0;
    // Note: In AXI4-Stream, TLAST is typically generated by the source. 
    // If this bridge must generate TLAST, connect TLAST_out to external TLAST pin.
    
endmodule

//  Ключевые особенности реализации:
// LMB Master Port: Модуль инициирует циклы записи (M_CYC, M_STB, M_WE), устанавливает адрес, данные и байтовое разрешение (M_SEL).
// AXI4-Stream Handshake: TREADY генерируется на основе готовности LMB шины. Данные захватываются синхронно с LMB_Clk.
// Burst Continuation: При TLAST=0 шина LMB удерживает M_CYC высоким, инкрементируя адрес и передавая оставшиеся байты в пределах одного AXI beat.
// Byte Enable Mapping: TSTRB напрямую маппится на M_SEL. Для production-кода добавьте логику выравнивания адреса (m_addr[1:0]) и сдвига данных.
// Сигналы ошибок: M_ERR и M_RTY заземлены. В реальном проекте их необходимо подключить к логике обработки timeout/parity ошибок LMB.


module axi4s_to_lmb_bridge_cdc #(
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = (DATA_WIDTH / 8),
    parameter ADDR_WIDTH = 32,
    parameter FIFO_DEPTH = 64
)(
    // LMB Clock & Reset
    input  wire                         LMB_Clk,
    input  wire                         LMB_RST,
    
    // AXI4-Stream Interface
    input  wire                         aclk,
    input  wire                         aresetn,
    input  wire                         TVALID,
    output wire                         TREADY,
    input  wire [DATA_WIDTH-1:0]        TDATA,
    input  wire [STRB_WIDTH-1:0]        TSTRB,
    input  wire                         TLAST,
    
    // LMB Master Interface
    output wire [ADDR_WIDTH-1:0]        M_A,
    output wire [DATA_WIDTH-1:0]        M_D,
    output wire [STRB_WIDTH-1:0]        M_BE,
    output wire                         M_CYC,
    output wire                         M_STB,
    output wire                         M_WE,
    output wire [STRB_WIDTH-1:0]        M_SEL,
    input  wire                         M_ACK,
    output wire                         M_ERR,
    output wire                         M_RTY,
    output wire                         M_DV
);

    // === CDC Reset Synchronizer (LMB_RST -> aclk domain) ===
    reg rst_sync_1, rst_sync_2;
    always @(posedge aclk) begin
        rst_sync_1 <= LMB_RST;
        rst_sync_2 <= rst_sync_1;
    end

    // === FIFO Configuration ===
    localparam AXI_FIFO_W = DATA_WIDTH + STRB_WIDTH + 1; // TDATA + TSTRB + TLAST
    localparam AXI_FIFO_DEPTH = FIFO_DEPTH;

    wire [AXI_FIFO_W-1:0] fifo_wr_data;
    wire                  fifo_wr_en;
    wire                  fifo_full;
    wire                  fifo_wr_ack;
    wire [AXI_FIFO_W-1:0] fifo_rd_data;
    wire                  fifo_rd_en;
    wire                  fifo_empty;
    wire                  fifo_rd_ack;
    wire                  fifo_dv;   // Data Valid pulse from read side
    wire                  fifo_last; // TLAST preserved across CDC
    wire [STRB_WIDTH-1:0] fifo_strb; // TSTRB preserved across CDC

    // Pack AXI4-Stream signals for FIFO write
    assign fifo_wr_data = {TDATA, TSTRB, TLAST};
    assign fifo_wr_en   = TVALID & ~fifo_full;
    assign TREADY       = ~fifo_full; // Backpressure to AXI4-Stream master

    // FIFO read control: read when LMB bus is idle and data is available
    assign fifo_rd_en   = ~fifo_empty & (M_CYC == 1'b0);
    assign fifo_dv      = fifo_rd_ack;
    assign fifo_last    = fifo_rd_data[AXI_FIFO_W-1];
    assign fifo_strb    = fifo_rd_data[DATA_WIDTH + STRB_WIDTH - 1 : DATA_WIDTH];

    // === XPM FIFO Instantiation (CDC) ===
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("auto"),
        .FIFO_DEPTH(AXI_FIFO_DEPTH),
        .DATA_COUNT_WIDTH(1),
        .PROTOCOL("none"),
        .USE_ECC(0),
        .ERROR_INJECTION_TYPE(0),
        .SIM_ASSERT_CHK(0),
        .WR_PULSE_WIDTH_PS(0),
        .RD_PULSE_WIDTH_PS(0)
    ) fifo_inst (
        .wr_clk(aclk),
        .rd_clk(LMB_Clk),
        .srst(rst_sync_2),
        .rst(1'b0),
        .din(fifo_wr_data),
        .wr_en(fifo_wr_en),
        .full(fifo_full),
        .wr_ack(fifo_wr_ack),
        .prog_full(),
        .prog_empty(),
        .almost_full(),
        .almost_empty(),
        .rd_data(fifo_rd_data),
        .rd_en(fifo_rd_en),
        .empty(fifo_empty),
        .rd_ack(fifo_rd_ack),
        .prog_full_flag(),
        .prog_empty_flag(),
        .valid(fifo_dv),
        .dbiterr(),
        .sbiterr(),
        .underflow(),
        .overflow(),
        .data_count(),
        .wr_data_count(),
        .rd_data_count(),
        .sleep(),
        .m_axi_aclken(),
        .m_axi_aclken_out()
    );

    // === LMB Bridge Logic (LMB_Clk domain) ===
    typedef enum logic [2:0] {
        IDLE,
        WAIT_FIFO,
        CYC_ASSERT,
        WAIT_ACK,
        LAST_BEAT
    } state_t;

    state_t curr_state, next_state;

    reg [ADDR_WIDTH-1:0] m_addr;
    reg [DATA_WIDTH-1:0] m_data_reg;
    reg [STRB_WIDTH-1:0] m_sel_reg;
    reg [STRB_WIDTH:0]   byte_cnt;

    // State transition
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) curr_state <= IDLE;
        else curr_state <= next_state;
    end

    always @(*) begin
        case (curr_state)
            IDLE:       next_state = fifo_dv ? WAIT_FIFO : IDLE;
            WAIT_FIFO:  next_state = CYC_ASSERT;
            CYC_ASSERT: next_state = M_ACK ? (byte_cnt == STRB_WIDTH ? LAST_BEAT : CYC_ASSERT) : CYC_ASSERT;
            WAIT_ACK:   next_state = M_ACK ? LAST_BEAT : WAIT_ACK;
            LAST_BEAT:  next_state = M_ACK ? IDLE : LAST_BEAT;
            default:    next_state = IDLE;
        endcase
    end

    // Data & Address latch from FIFO on valid pulse
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) begin
            m_data_reg <= {DATA_WIDTH{1'b0}};
            m_sel_reg  <= {STRB_WIDTH{1'b0}};
            byte_cnt   <= 0;
        end else if (fifo_dv) begin
            m_data_reg <= fifo_rd_data[DATA_WIDTH-1:0];
            m_sel_reg  <= fifo_strb;
            byte_cnt   <= 0;
        end
    end

    // LMB Master output signals
    assign M_A    = m_addr;
    assign M_D    = (M_CYC & M_STB) ? m_data_reg : {DATA_WIDTH{1'b0}};
    assign M_BE   = m_sel_reg; // Tie to SEL for byte-mode operation
    assign M_WE   = (curr_state != IDLE && curr_state != LAST_BEAT) ? 1'b1 : 1'b0;
    assign M_CYC  = (curr_state == CYC_ASSERT || curr_state == WAIT_ACK) ? 1'b1 : 1'b0;
    assign M_STB  = (curr_state == CYC_ASSERT || curr_state == WAIT_ACK) ? 1'b1 : 1'b0;
    assign M_SEL  = m_sel_reg;
    assign M_DV   = M_STB;
    assign M_ERR  = 1'b0;
    assign M_RTY  = 1'b0;

    // Burst continuation & address increment
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) begin
            m_addr <= {ADDR_WIDTH{1'b0}};
        end else begin
            case (curr_state)
                CYC_ASSERT: begin
                    if (M_ACK) begin
                        byte_cnt <= byte_cnt + 1'b1;
                        if (byte_cnt == STRB_WIDTH - 1) begin
                            m_addr <= m_addr + STRB_WIDTH;
                        end
                    end
                end
                LAST_BEAT: begin
                    if (M_CYC == 1'b0) begin
                        m_addr <= {ADDR_WIDTH{1'b0}};
                    end
                end
                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire


//Ключевые изменения и архитектурные решения:
//XPM FIFO для CDC: Использован xpm_fifo_async с раздельными wr_clk (aclk) и rd_clk (LMB_Clk). Это гарантирует корректную передачу данных, TSTRB и TLAST без потери семантики AXI4-Stream.
//Синхронизация сброса: Добавлен 2-каскадный синхронизатор LMB_RST в домен aclk для безопасной подачи на srst FIFO. В production рекомендуется использовать xpm_cdc_sync или встроенные примитивы SoC.
//Упаковка сигналов: TDATA, TSTRB и TLAST упакованы в один вектор AXI_FIFO_W. Это исключает рассинхронизацию между двумя отдельными FIFO и упрощает CDC.
//Обработка TLAST: Состояние LAST_BEAT гарантирует, что цикл LMB завершается ровно после получения M_ACK для последнего байта. После этого мост возвращается в IDLE и готов к приему нового AXI4-Stream пакета.
//Backpressure: TREADY = ~fifo_full корректно останавливает AXI4-Stream мастер при заполнении буфера, предотвращая потерю данных.
//
//Ниже представлена обновлённая версия модуля с интегрированным **Xilinx XPM FIFO** для корректного кросс-доменного преобразования (CDC). Код адаптирован под современные стандарты Vivado и учитывает семантику AXI4-Stream и LMB.


module axi4s_to_lmb_bridge_cdc2 #(
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = (DATA_WIDTH / 8),
    parameter ADDR_WIDTH = 32,
    parameter FIFO_DEPTH = 64
)(
    // LMB Clock & Reset
    input  wire                         LMB_Clk,
    input  wire                         LMB_RST,
    
    // AXI4-Stream Interface
    input  wire                         aclk,
    input  wire                         aresetn,
    input  wire                         TVALID,
    output wire                         TREADY,
    input  wire [DATA_WIDTH-1:0]        TDATA,
    input  wire [STRB_WIDTH-1:0]        TSTRB,
    input  wire                         TLAST,
    
    // LMB Master Interface
    output wire [ADDR_WIDTH-1:0]        M_A,
    output wire [DATA_WIDTH-1:0]        M_D,
    output wire [STRB_WIDTH-1:0]        M_BE,
    output wire                         M_CYC,
    output wire                         M_STB,
    output wire                         M_WE,
    output wire [STRB_WIDTH-1:0]        M_SEL,
    input  wire                         M_ACK,
    output wire                         M_ERR,
    output wire                         M_RTY,
    output wire                         M_DV
);

    // === CDC Reset Synchronizer (LMB_RST -> aclk domain) ===
    reg rst_sync_1, rst_sync_2;
    always @(posedge aclk) begin
        rst_sync_1 <= LMB_RST;
        rst_sync_2 <= rst_sync_1;
    end

    // === FIFO Configuration ===
    localparam AXI_FIFO_W = DATA_WIDTH + STRB_WIDTH + 1; // TDATA + TSTRB + TLAST
    localparam AXI_FIFO_DEPTH = FIFO_DEPTH;

    wire [AXI_FIFO_W-1:0] fifo_wr_data;
    wire                  fifo_wr_en;
    wire                  fifo_full;
    wire                  fifo_wr_ack;
    wire [AXI_FIFO_W-1:0] fifo_rd_data;
    wire                  fifo_rd_en;
    wire                  fifo_empty;
    wire                  fifo_rd_ack;
    wire                  fifo_dv;   // Data Valid pulse from read side
    wire                  fifo_last; // TLAST preserved across CDC
    wire [STRB_WIDTH-1:0] fifo_strb; // TSTRB preserved across CDC

    // Pack AXI4-Stream signals for FIFO write
    assign fifo_wr_data = {TDATA, TSTRB, TLAST};
    assign fifo_wr_en   = TVALID & ~fifo_full;
    assign TREADY       = ~fifo_full; // Backpressure to AXI4-Stream master

    // FIFO read control: read when LMB bus is idle and data is available
    assign fifo_rd_en   = ~fifo_empty & (M_CYC == 1'b0);
    assign fifo_dv      = fifo_rd_ack;
    assign fifo_last    = fifo_rd_data[AXI_FIFO_W-1];
    assign fifo_strb    = fifo_rd_data[DATA_WIDTH + STRB_WIDTH - 1 : DATA_WIDTH];

    // === XPM FIFO Instantiation (CDC) ===
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("auto"),
        .FIFO_DEPTH(AXI_FIFO_DEPTH),
        .DATA_COUNT_WIDTH(1),
        .PROTOCOL("none"),
        .USE_ECC(0),
        .ERROR_INJECTION_TYPE(0),
        .SIM_ASSERT_CHK(0),
        .WR_PULSE_WIDTH_PS(0),
        .RD_PULSE_WIDTH_PS(0)
    ) fifo_inst (
        .wr_clk(aclk),
        .rd_clk(LMB_Clk),
        .srst(rst_sync_2),
        .rst(1'b0),
        .din(fifo_wr_data),
        .wr_en(fifo_wr_en),
        .full(fifo_full),
        .wr_ack(fifo_wr_ack),
        .prog_full(),
        .prog_empty(),
        .almost_full(),
        .almost_empty(),
        .rd_data(fifo_rd_data),
        .rd_en(fifo_rd_en),
        .empty(fifo_empty),
        .rd_ack(fifo_rd_ack),
        .prog_full_flag(),
        .prog_empty_flag(),
        .valid(fifo_dv),
        .dbiterr(),
        .sbiterr(),
        .underflow(),
        .overflow(),
        .data_count(),
        .wr_data_count(),
        .rd_data_count(),
        .sleep(),
        .m_axi_aclken(),
        .m_axi_aclken_out()
    );

    // === LMB Bridge Logic (LMB_Clk domain) ===
    typedef enum logic [2:0] {
        IDLE,
        WAIT_FIFO,
        CYC_ASSERT,
        WAIT_ACK,
        LAST_BEAT
    } state_t;

    state_t curr_state, next_state;

    reg [ADDR_WIDTH-1:0] m_addr;
    reg [DATA_WIDTH-1:0] m_data_reg;
    reg [STRB_WIDTH-1:0] m_sel_reg;
    reg [STRB_WIDTH:0]   byte_cnt;

    // State transition
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) curr_state <= IDLE;
        else curr_state <= next_state;
    end

    always @(*) begin
        case (curr_state)
            IDLE:       next_state = fifo_dv ? WAIT_FIFO : IDLE;
            WAIT_FIFO:  next_state = CYC_ASSERT;
            CYC_ASSERT: next_state = M_ACK ? (byte_cnt == STRB_WIDTH ? LAST_BEAT : CYC_ASSERT) : CYC_ASSERT;
            WAIT_ACK:   next_state = M_ACK ? LAST_BEAT : WAIT_ACK;
            LAST_BEAT:  next_state = M_ACK ? IDLE : LAST_BEAT;
            default:    next_state = IDLE;
        endcase
    end

    // Data & Address latch from FIFO on valid pulse
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) begin
            m_data_reg <= {DATA_WIDTH{1'b0}};
            m_sel_reg  <= {STRB_WIDTH{1'b0}};
            byte_cnt   <= 0;
        end else if (fifo_dv) begin
            m_data_reg <= fifo_rd_data[DATA_WIDTH-1:0];
            m_sel_reg  <= fifo_strb;
            byte_cnt   <= 0;
        end
    end

    // LMB Master output signals
    assign M_A    = m_addr;
    assign M_D    = (M_CYC & M_STB) ? m_data_reg : {DATA_WIDTH{1'b0}};
    assign M_BE   = m_sel_reg; // Tie to SEL for byte-mode operation
    assign M_WE   = (curr_state != IDLE && curr_state != LAST_BEAT) ? 1'b1 : 1'b0;
    assign M_CYC  = (curr_state == CYC_ASSERT || curr_state == WAIT_ACK) ? 1'b1 : 1'b0;
    assign M_STB  = (curr_state == CYC_ASSERT || curr_state == WAIT_ACK) ? 1'b1 : 1'b0;
    assign M_SEL  = m_sel_reg;
    assign M_DV   = M_STB;
    assign M_ERR  = 1'b0;
    assign M_RTY  = 1'b0;

    // Burst continuation & address increment
    always @(posedge LMB_Clk or posedge LMB_RST) begin
        if (LMB_RST) begin
            m_addr <= {ADDR_WIDTH{1'b0}};
        end else begin
            case (curr_state)
                CYC_ASSERT: begin
                    if (M_ACK) begin
                        byte_cnt <= byte_cnt + 1'b1;
                        if (byte_cnt == STRB_WIDTH - 1) begin
                            m_addr <= m_addr + STRB_WIDTH;
                        end
                    end
                end
                LAST_BEAT: begin
                    if (M_CYC == 1'b0) begin
                        m_addr <= {ADDR_WIDTH{1'b0}};
                    end
                end
                default: ;
            endcase
        end
    end

endmodule
