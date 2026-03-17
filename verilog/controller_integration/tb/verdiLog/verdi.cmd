simSetSimulator "-vcssv" -exec \
           "/afs/umich.edu/class/eecs627/w26/groups/group7/project/verilog/controller_integration/tb/controller_integration_sim" \
           -args \
           "+MEMORY=controller_integration_sim.mem +TRACE=controller_integration_sim.base.trace +MEMACCESS=controller_integration_sim.base.memacc"
debImport "-dbdir" \
          "/afs/umich.edu/class/eecs627/w26/groups/group7/project/verilog/controller_integration/tb/controller_integration_sim.daidir"
debLoadSimResult \
           /afs/umich.edu/class/eecs627/w26/groups/group7/project/verilog/controller_integration/tb/integrated_tb.fsdb
wvCreateWindow
verdiSetActWin -win $_nWave2
verdiWindowResize -win $_Verdi_1 "0" "32" "1468" "900"
verdiSetActWin -dock widgetDock_MTB_SOURCE_TAB_1
srcHBSelect "controller_integration_tb.mmu_dut" -win $_nTrace1
srcHBSelect "controller_integration_tb.mmu_dut" -win $_nTrace1
verdiSetActWin -dock widgetDock_<Inst._Tree>
srcSetScope "controller_integration_tb.mmu_dut" -delim "." -win $_nTrace1
srcHBSelect "controller_integration_tb.mmu_dut" -win $_nTrace1
srcDeselectAll -win $_nTrace1
srcSelect -signal "i_clk" -line 6 -pos 1 -win $_nTrace1
verdiSetActWin -dock widgetDock_MTB_SOURCE_TAB_1
srcSelect -signal "i_rst_n" -line 7 -pos 1 -win $_nTrace1
srcSelect -signal "i_load_weights" -line 9 -pos 1 -win $_nTrace1
srcSelect -toggle -signal "i_load_weights" -line 9 -pos 1 -win $_nTrace1
srcDeselectAll -win $_nTrace1
srcSelect -signal "i_load_weights" -line 9 -pos 1 -win $_nTrace1
srcDeselectAll -win $_nTrace1
srcSelect -signal "i_clk" -line 6 -pos 1 -win $_nTrace1
srcSelect -signal "i_rst_n" -line 7 -pos 1 -win $_nTrace1
srcSelect -signal "i_load_weights" -line 9 -pos 1 -win $_nTrace1
srcSelect -signal "i_load_tile" -line 10 -pos 1 -win $_nTrace1
srcSelect -signal "i_store_tile" -line 11 -pos 1 -win $_nTrace1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
srcDeselectAll -win $_nTrace1
srcSelect -signal "i_N" -line 13 -pos 1 -win $_nTrace1
srcSelect -signal "i_W" -line 14 -pos 1 -win $_nTrace1
srcSelect -signal "i_H" -line 15 -pos 1 -win $_nTrace1
srcSelect -signal "i_words_per_channel" -line 16 -pos 1 -win $_nTrace1
srcSelect -signal "ADDR_WIDTH" -line 17 -pos 1 -win $_nTrace1
srcDeselectAll -win $_nTrace1
srcSelect -signal "i_tile_stride" -line 18 -pos 1 -win $_nTrace1
srcSelect -signal "i_words_per_channel" -line 16 -pos 1 -win $_nTrace1
srcSelect -signal "i_H" -line 15 -pos 1 -win $_nTrace1
srcSelect -signal "i_W" -line 14 -pos 1 -win $_nTrace1
srcSelect -signal "i_N" -line 13 -pos 1 -win $_nTrace1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
srcDeselectAll -win $_nTrace1
verdiFindBar -show -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "act" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "act" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "act" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "act" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "act" -next -widget MTB_SOURCE_TAB_1
srcDeselectAll -win $_nTrace1
srcSelect -signal "o_act_raddr" -line 426 -pos 1 -win $_nTrace1
srcSelect -signal "o_act_ren" -line 427 -pos 1 -win $_nTrace1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "o_act_r" -next -widget MTB_SOURCE_TAB_1
srcDeselectAll -win $_nTrace1
srcSelect -signal "i_act_rdata" -line 35 -pos 1 -win $_nTrace1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
srcDeselectAll -win $_nTrace1
srcSelect -signal "o_npu_wvalid" -line 57 -pos 1 -win $_nTrace1
srcSelect -signal "o_npu_wlast" -line 56 -pos 1 -win $_nTrace1
srcSelect -signal "o_npu_wstrb" -line 55 -pos 1 -win $_nTrace1
srcSelect -signal "o_npu_wdata" -line 54 -pos 1 -win $_nTrace1
srcSelect -signal "i_npu_wready" -line 58 -pos 1 -win $_nTrace1
srcSelect -signal "i_npu_awready" -line 53 -pos 1 -win $_nTrace1
srcSelect -signal "o_npu_awlen" -line 50 -pos 1 -win $_nTrace1
srcSelect -signal "o_npu_awaddr" -line 49 -pos 1 -win $_nTrace1
srcSelect -signal "o_npu_awsize" -line 51 -pos 1 -win $_nTrace1
srcSelect -toggle -signal "o_npu_awsize" -line 51 -pos 1 -win $_nTrace1
srcSelect -signal "o_npu_awsize" -line 51 -pos 1 -win $_nTrace1
srcSelect -signal "o_npu_awvalid" -line 52 -pos 1 -win $_nTrace1
srcSelect -signal "i_npu_bvalid" -line 59 -pos 1 -win $_nTrace1
srcSelect -signal "o_npu_bready" -line 60 -pos 1 -win $_nTrace1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
wvZoomIn -win $_nWave2
wvZoomIn -win $_nWave2
wvZoomIn -win $_nWave2
verdiSetActWin -win $_nWave2
wvZoomIn -win $_nWave2
wvZoomIn -win $_nWave2
wvSelectSignal -win $_nWave2 {( "G1" 5 )} 
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSelectSignal -win $_nWave2 {( "G1" 20 )} 
wvSelectSignal -win $_nWave2 {( "G1" 17 )} 
wvSetPosition -win $_nWave2 {("G1" 17)}
wvSetPosition -win $_nWave2 {("G1" 18)}
wvSetPosition -win $_nWave2 {("G1" 19)}
wvSetPosition -win $_nWave2 {("G1" 20)}
wvSetPosition -win $_nWave2 {("G1" 21)}
wvSetPosition -win $_nWave2 {("G1" 22)}
wvSetPosition -win $_nWave2 {("G1" 23)}
wvSetPosition -win $_nWave2 {("G1" 24)}
wvSetPosition -win $_nWave2 {("G1" 25)}
wvMoveSelected -win $_nWave2
wvSetPosition -win $_nWave2 {("G1" 25)}
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
srcHBSelect "controller_integration_tb.addr_dec_dut" -win $_nTrace1
verdiSetActWin -dock widgetDock_<Inst._Tree>
srcHBSelect "controller_integration_tb" -win $_nTrace1
srcSetScope "controller_integration_tb" -delim "." -win $_nTrace1
srcHBSelect "controller_integration_tb" -win $_nTrace1
srcDeselectAll -win $_nTrace1
srcSelect -signal "mem_wdata\[ 7: 0\]" -line 266 -pos 1 -win $_nTrace1
verdiSetActWin -dock widgetDock_MTB_SOURCE_TAB_1
srcDeselectAll -win $_nTrace1
srcSelect -signal "memory\[mem_addr >> 2\]\[ 7: 0\]" -line 266 -pos 1 -win \
          $_nTrace1
srcDeselectAll -win $_nTrace1
srcSelect -signal "mem_wdata\[ 7: 0\]" -line 266 -pos 1 -win $_nTrace1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
srcDeselectAll -win $_nTrace1
srcSelect -signal "mem_wdata\[31:24\]" -line 269 -pos 1 -win $_nTrace1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
wvSelectSignal -win $_nWave2 {( "G1" 26 )} 
verdiSetActWin -win $_nWave2
wvSelectSignal -win $_nWave2 {( "G1" 27 )} 
wvSelectSignal -win $_nWave2 {( "G1" 26 27 )} 
wvCut -win $_nWave2
wvSetPosition -win $_nWave2 {("G1" 25)}
srcDeselectAll -win $_nTrace1
verdiSetActWin -dock widgetDock_MTB_SOURCE_TAB_1
verdiFindBar -show -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "mem_wdata" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "mem_wdata" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "mem_wdata" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "mem_wdata" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "mem_wdata" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "mem_wdata" -next -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "mem_wdata" -next -widget MTB_SOURCE_TAB_1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
wvSearchNext -win $_nWave2
verdiSetActWin -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
srcDeselectAll -win $_nTrace1
verdiSetActWin -dock widgetDock_MTB_SOURCE_TAB_1
verdiFindBar -show -widget MTB_SOURCE_TAB_1
verdiFindBar -pattern "mem_wdata" -next -widget MTB_SOURCE_TAB_1
srcDeselectAll -win $_nTrace1
srcSelect -signal "mem_wdata\[31:24\]" -line 269 -pos 1 -win $_nTrace1
srcSelect -win $_nTrace1 -range {268 269 12 12 7 8} -backward
srcDeselectAll -win $_nTrace1
srcDeselectAll -win $_nTrace1
srcSelect -signal "mem_wdata\[ 7: 0\]" -line 266 -pos 1 -win $_nTrace1
srcSelect -signal "mem_wdata\[15: 8\]" -line 267 -pos 1 -win $_nTrace1
srcSelect -signal "mem_wdata\[23:16\]" -line 268 -pos 1 -win $_nTrace1
srcSelect -toggle -signal "mem_wdata\[23:16\]" -line 268 -pos 1 -win $_nTrace1
srcSelect -signal "mem_wdata\[23:16\]" -line 268 -pos 1 -win $_nTrace1
srcSelect -signal "mem_wdata\[31:24\]" -line 269 -pos 1 -win $_nTrace1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
srcDeselectAll -win $_nTrace1
srcSelect -signal "mem_wstrb" -line 265 -pos 1 -win $_nTrace1
srcDeselectAll -win $_nTrace1
srcSelect -signal "mem_ready" -line 261 -pos 1 -win $_nTrace1
srcDeselectAll -win $_nTrace1
srcSelect -signal "mem_valid" -line 260 -pos 1 -win $_nTrace1
srcSelect -signal "mem_ready" -line 260 -pos 1 -win $_nTrace1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
srcDeselectAll -win $_nTrace1
srcSelect -signal "memory\[mem_addr >> 2\]\[23:16\]" -line 268 -pos 1 \
          -partailSelPos 13 -win $_nTrace1
srcAddSelectedToWave -clipboard -win $_nTrace1
wvDrop -win $_nWave2
wvSearchNext -win $_nWave2
verdiSetActWin -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchNext -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvSearchPrev -win $_nWave2
wvScrollUp -win $_nWave2 7
wvScrollDown -win $_nWave2 8
wvScrollUp -win $_nWave2 8
wvSelectSignal -win $_nWave2 {( "G1" 20 )} 
wvSearchPrev -win $_nWave2
srcHBSelect "controller_integration_tb.mmu_dut" -win $_nTrace1
srcSetScope "controller_integration_tb.mmu_dut" -delim "." -win $_nTrace1
srcHBSelect "controller_integration_tb.mmu_dut" -win $_nTrace1
verdiSetActWin -dock widgetDock_<Inst._Tree>
