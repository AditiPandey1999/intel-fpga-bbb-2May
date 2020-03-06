//
// Copyright (c) 2020, Intel Corporation
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// Neither the name of the Intel Corporation nor the names of its contributors
// may be used to endorse or promote products derived from this software
// without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

//
// Add an MPF pipeline, including VTP, to the primary CCI-P interface.
// Add a separate VTP service to the G1 ports, if present. Use virtual
// addresses in the test engine.
//

`include "ofs_plat_if.vh"
`include "cci_mpf_if.vh"

module afu
  #(
    parameter NUM_PORTS_G1 = 0
    )
   (
    // Primary host interface
    ofs_plat_host_ccip_if.to_fiu host_ccip_if,

    // Secondary host memory interface (as Avalon). Zero length vectors are illegal.
    // Force minimum size 1 dummy entry in case no secondary ports exist.
    ofs_plat_avalon_mem_rdwr_if.to_slave host_mem_g1_if[NUM_PORTS_G1 > 0 ? NUM_PORTS_G1 : 1],

    // pClk is used to compute the frequency of the AFU's clk, since pClk
    // is a known frequency.
    input  logic pClk,

    // AFU Power State
    input  t_ofs_plat_power_state pwrState
    );

    logic clk;
    assign clk = host_ccip_if.clk;
    logic reset;
    assign reset = host_ccip_if.reset;

    localparam NUM_PORTS_G0 = 1;
    localparam NUM_ENGINES = NUM_PORTS_G0 + NUM_PORTS_G1;

    // Byte address of MPF's CSRs
    localparam PRIMARY_MPF_MMIO_BASE_ADDR = 'h5000;


    // ====================================================================
    //
    //  Instantiate the VTP service for use by the host channel.
    //  The VTP service is an OFS CCI-P to OFS CCI-P shim that injects
    //  MMIO and page table traffic into the interface. The VTP
    //  translation ports are a separate interface that will be passed
    //  to the AFU memory engines.
    //
    // ====================================================================

    // One port for each of read and write ports
    localparam N_VTP_PORTS = (NUM_PORTS_G1 > 0) ? NUM_PORTS_G1 * 2 : 1;
    mpf_vtp_port_if vtp_ports[N_VTP_PORTS]();

    // Byte address of VTP CSRs
    localparam VTP_MMIO_BASE_ADDR = 'h4000;
    localparam AFU_NEXT_MMIO_ADDR = (NUM_PORTS_G1 > 0 ? VTP_MMIO_BASE_ADDR :
                                                        PRIMARY_MPF_MMIO_BASE_ADDR);

    ofs_plat_host_ccip_if afu_ccip_if();

    generate
        if (NUM_PORTS_G1 > 0)
        begin : v
            mpf_vtp_svc_ofs_ccip
              #(
                // Use a unique MPF instance ID for the group 1 VTP service.
                // The primary MPF instance ID on the main CCI-P port is 1.
                .MPF_INSTANCE_ID(2),
                // VTP's CSR byte address. The AFU will add this address to
                // the feature list.
                .DFH_MMIO_BASE_ADDR(VTP_MMIO_BASE_ADDR),
                .DFH_MMIO_NEXT_ADDR(PRIMARY_MPF_MMIO_BASE_ADDR),
                .N_VTP_PORTS(N_VTP_PORTS),
                // The primary MPF instance (cci_mpf below) uses mdata bit
                // CCIP_MDATA_WIDTH-2 to signal internal DMA requests, but
                // guarantees never to set both CCIP_MDATA_WIDTH-2 and -3.
                // This VTP instance uses those two bits together to mark
                // internal DMA requests. (The top mdata bit is reserved for
                // use by the CCI-P MUX that is used for tests that emulate
                // multiple host channel groups, so can't be used here.)
                .MDATA_TAG_MASK('b11 << (CCIP_MDATA_WIDTH-3))
                )
              vtp_svc
               (
                .to_fiu(host_ccip_if),
                .to_afu(afu_ccip_if),
                .vtp_ports
                );
        end
        else
        begin : nv
            // VTP not needed. Don't use the shim -- just wire to the next
            // CCI-P stage.
            ofs_plat_ccip_if_connect conn_mpf(.to_fiu(host_ccip_if), .to_afu(afu_ccip_if));
        end
    endgenerate


    // ====================================================================
    //
    //  Instantiate MPF on the primary port. MPF will provide a separate
    //  VTP service here as well as memory property shims, such as
    //  response ordering.
    //
    // ====================================================================

    cci_mpf_if#(.ENABLE_LOG(1)) mpf_to_fiu(.clk);
    cci_mpf_if#(.ENABLE_LOG(1)) mpf_to_afu(.clk);

    // Map OFS CCI-P to MPF's interface
    ofs_plat_ccip_if_to_mpf
      #(
        // CCI-P interface is already registered by the OFS PIM
        .REGISTER_INPUTS(0),
        .REGISTER_OUTPUTS(0)
        )
      map_ifc
       (
        .ofs_ccip(afu_ccip_if),
        .mpf_ccip(mpf_to_fiu)
        );

    cci_mpf
      #(
        .DFH_MMIO_BASE_ADDR(PRIMARY_MPF_MMIO_BASE_ADDR),
        // MPF terminates the feature list
        .DFH_MMIO_NEXT_ADDR(0),

        // Enable virtual to physical translation
        .ENABLE_VTP(1),
        // Don't halt VTP on translation failure. Let the AFU deal with
        // untranslatable addresses.
        .VTP_HALT_ON_FAILURE(0),

        // VC map is used only on older platforms with multiple physical
        // channels mapped to one logical CCI-P port. VC map is required
        // when ENFORCE_WR_ORDER is set, so it is enabled here.
        .ENABLE_VC_MAP(1),

        // Enforce write/write and write/read ordering with cache lines
        .ENFORCE_WR_ORDER(1),

        // Return read responses in the order they were requested
        .SORT_READ_RESPONSES(1),

        // Preserve Mdata field in write requests.
        .PRESERVE_WRITE_MDATA(1)
        )
      mpf_primary
       (
        .clk,
        .fiu(mpf_to_fiu),
        .afu(mpf_to_afu),
        .c0NotEmpty(),
        .c1NotEmpty()
        );


    // ====================================================================
    //
    //  Split the MPF AFU interface into separate host memory and MMIO
    //  interfaces.
    //
    // ====================================================================

    cci_mpf_if mpf_host_mem(.clk);
    cci_mpf_if mpf_mmio(.clk);

    mpf_if_split_mmio split_mmio
       (
        .clk,
        .to_fiu(mpf_to_afu),
        .host_mem(mpf_host_mem),
        .mmio(mpf_mmio)
        );


    // ====================================================================
    //
    //  Global CSRs (mostly to tell SW about the AFU configuration)
    //
    // ====================================================================

    engine_csr_if eng_csr_glob();
    engine_csr_if eng_csr[NUM_ENGINES]();

    // Unique ID for this test
    logic [127:0] test_id = 128'h9dcf6fcd_3699_4979_956a_666f7cff59d6;

    always_comb
    begin
        eng_csr_glob.rd_data[0] = test_id[63:0];
        eng_csr_glob.rd_data[1] = test_id[127:64];
        eng_csr_glob.rd_data[2] = { 48'd0, 8'(NUM_PORTS_G1), 8'(NUM_PORTS_G0) };

        for (int e = 3; e < eng_csr_glob.NUM_CSRS; e = e + 1)
        begin
            eng_csr_glob.rd_data[e] = 64'(0);
        end

        // This signal means nothing
        eng_csr_glob.status_active = 1'b0;
    end


    // ====================================================================
    //
    //  Engine for primary interface (the one routed through MPF)
    //
    // ====================================================================

    // Convert the MPF interface to a normal OFS CCI-P interface
    ofs_plat_host_ccip_if host_mem_va_if();
    t_cci_mpf_ReqMemHdrExt cTx_ext;

    // MPF extension header, used for things like requesting virtual to
    // physical translation. This must be passed in along with the
    // generic OFS CCI-P interface in order to configure MPF requests.
    always_comb
    begin
        cTx_ext = '0;
        cTx_ext.addrIsVirtual = 1'b1;
    end

    mpf_if_to_ofs_plat_ccip hm
       (
        .clk,
        .error(host_ccip_if.error),
        .mpf_ccip(mpf_host_mem),
        .ofs_ccip(host_mem_va_if),
        .c0Tx_ext(cTx_ext),
        .c1Tx_ext(cTx_ext),
        // MPF partial writes not used in this test
        .c1Tx_pwrite('0)
        );

    host_mem_rdwr_engine_ccip
      #(
        .ENGINE_NUMBER(0)
        )
      eng
       (
        .host_mem_if(host_mem_va_if),
        .csrs(eng_csr[0])
        );


    genvar p;
    generate
        // Instantiate traffic generators for the group 1 ports
        for (p = 0; p < NUM_PORTS_G1; p = p + 1)
        begin : g1
            g1_worker
              #(
                .ENGINE_NUMBER(NUM_PORTS_G0 + p)
                )
              wrk
               (
                .host_mem_if(host_mem_g1_if[p]),
                .csrs(eng_csr[NUM_PORTS_G0 + p]),

                .vtp_ports(vtp_ports[p*2 : p*2+1])
                );
        end
    endgenerate


    // ====================================================================
    //
    //  Instantiate control via CSRs
    //
    // ====================================================================

    t_ccip_c0_ReqMmioHdr mmio_hdr;
    assign mmio_hdr = t_ccip_c0_ReqMmioHdr'(mpf_mmio.c0Rx.hdr);

    // Tie off unused Tx ports
    assign mpf_mmio.c0Tx = '0;
    assign mpf_mmio.c1Tx = '0;

    csr_mgr
      #(
        .NUM_ENGINES(NUM_ENGINES),
        .DFH_MMIO_NEXT_ADDR(AFU_NEXT_MMIO_ADDR),
        // Convert to QWORD index space (drop the low address bit)
        .MMIO_ADDR_WIDTH(CCIP_MMIOADDR_WIDTH - 1)
        )
      csr_mgr
       (
        .clk(mpf_mmio.clk),
        .reset(mpf_mmio.reset),
        .pClk,

        .wr_write(mpf_mmio.c0Rx.mmioWrValid),
        .wr_address(mmio_hdr.address[CCIP_MMIOADDR_WIDTH-1 : 1]),
        .wr_writedata(mpf_mmio.c0Rx.data[63:0]),

        .rd_read(mpf_mmio.c0Rx.mmioRdValid),
        .rd_address(mmio_hdr.address[CCIP_MMIOADDR_WIDTH-1 : 1]),
        .rd_tid_in(mmio_hdr.tid),
        .rd_readdatavalid(mpf_mmio.c2Tx.mmioRdValid),
        .rd_readdata(mpf_mmio.c2Tx.data),
        .rd_tid_out(mpf_mmio.c2Tx.hdr.tid),

        .eng_csr_glob,
        .eng_csr
        );

endmodule // afu


module g1_worker
  #(
    parameter ENGINE_NUMBER = 0
    )
   (
    ofs_plat_avalon_mem_rdwr_if.to_slave host_mem_if,
    engine_csr_if.engine csrs,

    mpf_vtp_port_if.to_slave vtp_ports[2]
    );

    logic clk;
    assign clk = host_mem_if.clk;
    logic reset;
    assign reset = host_mem_if.reset;

    // Generate a host memory interface that accepts virtual addresses.
    // The code below will connect it to the host_mem_if, which expects
    // IOVAs, performing the translation using the two VTP ports.
    ofs_plat_avalon_mem_rdwr_if
      #(
        `OFS_PLAT_AVALON_MEM_RDWR_IF_REPLICATE_PARAMS(host_mem_if),
        .LOG_CLASS(ofs_plat_log_pkg::HOST_CHAN)
        )
      host_mem_va_if();

    assign host_mem_va_if.clk = host_mem_if.clk;
    assign host_mem_va_if.reset = host_mem_if.reset;
    assign host_mem_va_if.instance_number = host_mem_if.instance_number;

    mpf_vtp_translate_ofs_avalon_mem_rdwr vtp
       (
        .host_mem_if,
        .host_mem_va_if,
        .error_c0(),
        .error_c1(),
        .vtp_ports
        );

    host_mem_rdwr_engine_avalon
      #(
        .ENGINE_NUMBER(ENGINE_NUMBER)
        )
      eng
       (
        .host_mem_if(host_mem_va_if),
        .csrs
        );

endmodule // g1_worker
