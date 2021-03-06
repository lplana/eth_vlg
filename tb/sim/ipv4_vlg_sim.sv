package sim_ipv4_pkg;
import sim_base_pkg::*;
import ip_vlg_pkg::*;
import eth_vlg_pkg::*;
import mac_vlg_pkg::*;
import eth_vlg_pkg::*;

class device_ipv4_c extends device_base_c;

  task automatic ipv4_parse;
    input byte data_in [];
    output byte data [];
    output ipv4_hdr_t hdr;
    output bit ok = 0;
    int len = data_in.size();
    hdr = {>>{data_in with [0:19]}};
	  data = new[data_in.size()-20];
	  data = {>>{data_in with [20:data_in.size()]}};
    if (hdr.ihl != 5) begin
      $error("IPv4 parser error: IPv4 Options not supported");
      disable ipv4_parse;
	  end
    ok = 1;
  endtask : ipv4_parse

  task automatic ipv4_gen;
    input  byte data_in [];
    output byte data [];
    input  ipv4_hdr_t hdr;
    input  mac_addr_t src_mac; // Source MAC
    input  mac_addr_t dst_mac; // Destination MAC
    output mac_hdr_t  mac_hdr;
    begin
      {>>{data with [0:IPV4_HDR_LEN-1]}} = hdr;
      data = {data, data_in};
      mac_hdr.ethertype = 16'h0800;
      mac_hdr.src_mac_addr = src_mac;
      mac_hdr.dst_mac_addr = dst_mac;
    end
  endtask : ipv4_gen

endclass : device_ipv4_c

endpackage : sim_ipv4_pkg