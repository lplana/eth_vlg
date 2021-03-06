import mac_vlg_pkg::*;
import eth_vlg_pkg::*;

interface phy;
  logic       clk;
  logic       rst;
  logic [7:0] dat;
  logic       val;
  logic       err;
  
  modport in  (input  clk, rst, dat, val, err);
  modport out (output clk, rst, dat, val, err);
endinterface

interface mac;
  logic [7:0] dat;
  logic       val;
  logic       err; // not yet implememnted
  logic       sof;
  logic       eof;
  logic       rdy; // Mac is ready to accept data
  logic       avl; // Indicate MAC that data is avalable for it
  mac_hdr_t   hdr; // MAC header

  modport in  (input dat, val, err, sof, eof, hdr, avl, output rdy);
  modport out (output dat, val, err, sof, eof, hdr, avl, input rdy);
endinterface

module mac_vlg #(
  parameter int TX_FIFO_SIZE = 8,
  parameter int CDC_FIFO_DEPTH = 8,
  parameter int CDC_DELAY = 4,
  parameter bit VERBOSE = 1
)
(
  input logic clk,
  input logic rst,

  phy.in  phy_rx,
  phy.out phy_tx,

  output  logic rst_fifo,
  input   dev_t dev,

  mac.out rx,
  mac.in  tx
);

phy phy_rx_sync (.*);

logic [7:0] phy_rx_d;
logic phy_rx_v;
logic phy_rx_e;

// Syncronyze 125MHz phy_rx_clk
// to local 125 MHz clock
// Delay reading for a few ticks
// in order to avoid packet rip
// which may be casued due
// to clocks being incoherent

mac_vlg_cdc #(  
  .FIFO_DEPTH (CDC_FIFO_DEPTH),
  .DELAY      (CDC_DELAY)
) mac_vlg_cdc_inst (
  // phy_rx_clk domain
  .clk_in     (phy_rx.clk),      // in
  .rst_in     (phy_rx.rst),      // in
  .data_in    (phy_rx.dat),      // in
  .valid_in   (phy_rx.val),      // in
  .error_in   (phy_rx.err),      // in
  // local clock domain
  .clk_out    (clk),             // in 
  .rst_out    (rst),             // in 
  .data_out   (phy_rx_sync.dat), // out
  .valid_out  (phy_rx_sync.val), // out
  .error_out  (phy_rx_sync.err)  // out
);


mac_vlg_rx #(
  .VERBOSE (VERBOSE)
) mac_vlg_rx_inst (
  .clk      (clk),
  .rst      (rst),
  .dev      (dev),
  .phy      (phy_rx_sync),
  .mac      (rx)
);

mac_vlg_tx #(
  .VERBOSE (VERBOSE)
) mac_vlg_tx_inst (
  .clk      (clk),
  .rst      (rst),
  .rst_fifo (rst_fifo),
  .dev      (dev),
  .phy      (phy_tx),
  .mac      (tx)
);

endmodule

module mac_vlg_rx #(
  parameter bit VERBOSE = 1
)(
  input logic clk,
  input logic rst,
  phy.in      phy,
  mac.out     mac,
  input dev_t dev
);

localparam MAC_HDR_LEN = 22;
fsm_t fsm;

logic fsm_rst;

logic [15:0] byte_cnt;

logic fcs_detected;
logic crc_en;

logic [4:0][7:0] rxd_delay;
logic [1:0]      rxv_delay;

logic error;
logic receiving;

logic [7:0] hdr [MAC_HDR_LEN-1:0];

crc32 crc32_inst(
  .clk (clk),
  .rst (fsm_rst),
  .dat (phy.dat),
  .val (crc_en),
  .ok  (fcs_detected),
  .crc ()
);

always @ (posedge clk) begin
  if (fsm_rst) begin
    byte_cnt  <= 0;
    crc_en    <= 0;
    mac.hdr   <= '0;
    mac.val   <= 0;
    mac.sof   <= 0;
    receiving <= 0;
    error     <= 0;
  end
  else begin
    mac.sof <= (byte_cnt == 27);  
    if (phy.val) begin // Write to header and shift it 
      hdr[0] <= rxd_delay[4];
      hdr[MAC_HDR_LEN-1:1] <= hdr[MAC_HDR_LEN-2:0]; 
      byte_cnt <= byte_cnt + 1;
    end
    if (fcs_detected) begin
      mac.hdr.length <= byte_cnt; // Latch length
    end
    if (!rxv_delay[0] && phy.val) receiving <= 1;
    if (byte_cnt == 7) crc_en <= 1;
    if (byte_cnt == 27) begin
      mac.val <= 1;
      mac.hdr.ethertype    <= {hdr[1],  hdr[0]};
      mac.hdr.src_mac_addr <= {hdr[7],  hdr[6],  hdr[5],  hdr[4],  hdr[3], hdr[2]};
      mac.hdr.dst_mac_addr <= {hdr[13], hdr[12], hdr[11], hdr[10], hdr[9], hdr[8]};
    end

  end
end

always @ (posedge clk) begin
  rxd_delay[4:0] <= {rxd_delay[3:0], phy.dat};
  rxv_delay[1:0] <= {rxv_delay[0], phy.val};
  fsm_rst <= (fcs_detected || mac.err || rst);

  mac.dat <= rxd_delay[4];
  mac.err = (!phy.val && rxv_delay[0] && !fcs_detected);
  mac.eof <= fcs_detected;
end

endmodule : mac_vlg_rx

module mac_vlg_tx #(
  parameter bit VERBOSE = 1
)(
  input logic clk,
  input logic rst,
  output logic rst_fifo,

  phy.out phy,
  mac.in  mac,

  input  dev_t dev
);

localparam MIN_DATA_PORTION = 44;
assign phy.clk = clk;

// todo: remove fifo

fifo_sc_if #(8, 8) fifo(.*);
fifo_sc #(8, 8) fifo_inst(.*);

assign fifo.clk = clk;
assign fifo.rst = rst;

assign fifo.write = mac.val;
assign fifo.data_in = mac.dat;

fsm_t fsm;

logic fsm_rst;
logic done;
logic pad_ok;

mac_hdr_t cur_hdr;
dev_t     cur_dev;

logic [2:0] preamble_byte_cnt;
logic [2:0] dst_byte_cnt;
logic [2:0] src_byte_cnt;
logic [1:0] tag_byte_cnt;
logic [0:0] ethertype_byte_cnt;
logic [2:0] fcs_byte_cnt;

logic [5:0] byte_cnt;

logic [31:0] crc_inv;
logic [31:0] crc;
logic [31:0] cur_fcs;
logic        crc_en;
logic  [7:0] d_hdr;
logic  [7:0] d_fcs;
logic  [7:0] d_hdr_delay;

assign crc = ~crc_inv;

assign rst_fifo = fsm_rst;

crc32 crc32_inst(
  .clk (clk),
  .rst (rst),
  .dat (d_hdr),
  .val (crc_en),
  .ok  (),
  .crc (crc_inv)
);

// assign mac.busy = rdy;

always @ (posedge clk) begin
  if (fsm_rst) begin
    fsm <= idle_s;
    preamble_byte_cnt  <= 0;
    dst_byte_cnt       <= 0;
    src_byte_cnt       <= 0;
    tag_byte_cnt       <= 0;
    ethertype_byte_cnt <= 0;
    fcs_byte_cnt       <= 0;
    byte_cnt           <= 0;
    mac.rdy            <= 0;
    crc_en             <= 0;
    d_hdr              <= 0;
    phy.val            <= 0;
    done               <= 0;
    pad_ok             <= 0;
    fifo.read          <= 0;
  end
  else begin
    case (fsm)
      idle_s : begin
        if (mac.avl) mac.rdy <= 1; // if a packet is available from IPv4 or ARP and MAC is ready to transmit, indicate it by asserting rdy
        if (mac.rdy) begin // 
          fsm <= pre_s;
          d_hdr <= 8'h55;
          cur_hdr.src_mac_addr <= dev.mac_addr;
          cur_hdr.dst_mac_addr <= mac.hdr.dst_mac_addr;
          cur_hdr.ethertype    <= mac.hdr.ethertype;          
          cur_dev <= dev;
        end
      end
      pre_s : begin
        phy.val <= 1;
        preamble_byte_cnt <= preamble_byte_cnt + 1;
        if (preamble_byte_cnt == 6) begin
          d_hdr <= 8'hd5;
          fsm <= dst_s;
        end
      end
      dst_s : begin
        crc_en <= 1;
        dst_byte_cnt <= dst_byte_cnt + 1;
        d_hdr <= cur_hdr.dst_mac_addr[5];
        cur_hdr.dst_mac_addr[5:1] <= cur_hdr.dst_mac_addr[4:0];
        if (dst_byte_cnt == 5) fsm <= src_s;
      end
      src_s : begin
        src_byte_cnt <= src_byte_cnt + 1;
        d_hdr <= cur_dev.mac_addr[5];
        cur_dev.mac_addr[5:1] <= cur_dev.mac_addr[4:0];
        if (src_byte_cnt == 5) fsm <= type_s;        
      end
      qtag_s : begin
        // Not supported currently
      end
      type_s : begin
        ethertype_byte_cnt <= ethertype_byte_cnt + 1;
        d_hdr <= cur_hdr.ethertype[1];
        cur_hdr.ethertype[1] <= cur_hdr.ethertype[0];
        fifo.read <= 1; // begin reading data ARP or IPv4 packet from buf_mng
        if (ethertype_byte_cnt == 1) begin
          fsm <= payload_s;
          mac.rdy <= 1;
        end
      end
      payload_s : begin
        byte_cnt <= byte_cnt + 1;
        mac.rdy <= 0;
        d_hdr <= fifo.data_out;
        if (byte_cnt == MIN_DATA_PORTION) pad_ok <= 1;
        if (fifo.empty && pad_ok) begin
          fsm <= fcs_s;
        end
      end
      fcs_s : begin
        crc_en <= 0;
        fcs_byte_cnt <= fcs_byte_cnt + 1;
        cur_fcs <= (fcs_byte_cnt == 1) ? {crc[7:0], crc[15:8], crc[23:16], crc[31:24]} : cur_fcs << 8;
         if (fcs_byte_cnt == 4) begin
          if (VERBOSE) $display("[DUT]-> Frame from %h:%h:%h:%h:%h:%h to %h:%h:%h:%h:%h:%h. Ethertype: %h",
            dev.mac_addr[5],
            dev.mac_addr[4],
            dev.mac_addr[3],
            dev.mac_addr[2],
            dev.mac_addr[1],
            dev.mac_addr[0],   
            mac.hdr.dst_mac_addr[5],
            mac.hdr.dst_mac_addr[4],
            mac.hdr.dst_mac_addr[3],
            mac.hdr.dst_mac_addr[2],
            mac.hdr.dst_mac_addr[1],
            mac.hdr.dst_mac_addr[0],
            mac.hdr.ethertype
          );
          done <= 1;
        end
      end
    endcase
  end
end

logic [7:0] fifo_r_q;
logic fifo_e;

assign fifo_r_q = fifo.data_out;
assign fifo_e = fifo.empty;

assign fsm_rst = (rst || done);

assign d_fcs = cur_fcs[31-:8];

always @ (posedge clk) d_hdr_delay <= d_hdr;

assign phy.dat = (fcs_byte_cnt == 0 || fcs_byte_cnt == 1) ? d_hdr_delay : d_fcs;

endmodule : mac_vlg_tx

module mac_vlg_cdc #(
  parameter FIFO_DEPTH = 8, // The value should be reasonable for the tool to implement DP RAM
  parameter DELAY = 4 
)(
  input  logic       clk_in,
  input  logic       rst_in,
  input  logic [7:0] data_in,
  input  logic       valid_in,
  input  logic       error_in,

  input  logic       clk_out,
  input  logic       rst_out,
  output logic [7:0] data_out,
  output logic       valid_out,
  output logic       error_out
);

// Introduce a readout delay to make sure valid_out will have no interruptions 
// because rx_clk and clk are asynchronous 
logic [DELAY-1:0] empty;
fifo_dc_if #(FIFO_DEPTH, 8) fifo(.*);
fifo_dc    #(FIFO_DEPTH, 8) fifo_inst(.*);

assign fifo.clk_w = clk_in;
assign fifo.rst_w = rst_in;

assign fifo.data_in = data_in;
assign fifo.write = valid_in;

assign fifo.clk_r = clk_out;
assign fifo.rst_r = rst_out;

assign data_out  = fifo.data_out;
assign valid_out = fifo.valid_out;

always @ (posedge clk_out) begin
  empty[DELAY-1:0] <= {empty[DELAY-2:0], fifo.empty};
  fifo.read <= ~empty[DELAY-1];
end

endmodule
