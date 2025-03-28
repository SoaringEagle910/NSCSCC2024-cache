`timescale 1ns / 1ps
`define ADDR_SIZE 32
`define DATA_SIZE 32


`define TAG_SIZE 20
`define INDEX_SIZE 7
`define OFFSET_SIZE 5
`define TAG_LOC 31:12
`define INDEX_LOC 11:5
`define OFFSET_LOC 4:0

`define BANK_NUM 8 
`define BANK_SIZE 32
`define SET_SIZE 128
`define TAGV_SIZE 21


`define IDLE 5'b00001//得到第一个pc命中结果，开始准备判断第二个pc命中结果，若未命中则
`define ASKMEM1 5'b00010
`define ASKMEM2 5'b00100
`define RETURN 5'b01000
`define UNCACHE_RETURN 5'b10000



module icache 
    import pipeline_types::*;
(
    input logic clk,
    input logic reset,
    input logic pause_icache,//给icache的pause信号
    input logic branch_flush,//这个信号是不是还有，而且我会传给axi，当flush的时候，axi也不用从主存读了？就不会给我返回ret_valid了？
    //front-icache
    pc_icache pc2icache,
    icache_transaddr icache2transaddr,
    //icache-axi
    output logic rd_req,
    output bus32_t rd_addr,
    output logic flush,
    input logic ret_valid,
    input bus256_t ret_data,

    input  logic             icacop_op_en   ,//使能信号
    input  logic[ 1:0]       icacop_op_mode  ,//缓存操作的模式
    input bus32_t icacop_addr,

    output logic iucache_ren_i,
    output bus32_t iucache_addr_i,
    input logic iucache_rvalid_o,
    input bus32_t iucache_rdata_o
);

logic real_ret_valid,drop_one_ret,real_uncache_ret_valid;
always_ff @( posedge clk ) begin
    if(reset)drop_one_ret<=1'b0;
    else if(branch_flush&&!ret_valid&&!iucache_rvalid_o)drop_one_ret<=1'b1;
    else if(ret_valid)drop_one_ret<=1'b0;
    else if(iucache_rvalid_o)drop_one_ret<=1'b0;
    else drop_one_ret<=drop_one_ret;
end

assign real_uncache_ret_valid=(drop_one_ret||branch_flush)?1'b0:iucache_rvalid_o;
assign real_ret_valid=(drop_one_ret||branch_flush)?1'b0:ret_valid;

logic pre_valid;
always_ff @( posedge clk ) begin
    if(pc2icache.stall||pause_icache)pre_valid<=pre_valid;
    else pre_valid<=|pc2icache.inst_en;
end

logic a_hit_success,a_hit_fail,b_hit_success,b_hit_fail;
logic record_b_hit_result,record_a_hit_result;

logic same_way;

logic paused_ret_valid;
always_ff @( posedge clk ) begin
    if(!pause_icache)paused_ret_valid<=1'b0;
    else if((real_ret_valid||real_uncache_ret_valid)&&pause_icache)paused_ret_valid<=1'b1;
    else paused_ret_valid<=paused_ret_valid;
end

logic[4:0]current_state,next_state;

logic write_delay;
always_ff @( posedge clk ) begin
    if(reset)write_delay<=1'b0;
    else if(pause_icache)write_delay<=write_delay;
    else if(write_delay==1'b1)write_delay<=1'b0;
    else if(next_state==`RETURN)write_delay<=1'b1;
    else write_delay<=1'b0;
end

logic flush_delay;
always_ff @( posedge clk ) begin
    flush_delay<=branch_flush;
end

always_ff @( posedge clk ) begin
    if(reset)current_state<=`IDLE;
    else current_state<=next_state;
end
logic pre_uncache_en;
always_ff @( posedge clk ) begin
    if(pc2icache.stall)pre_uncache_en<=pre_uncache_en;
    else pre_uncache_en<=pc2icache.uncache_en;
end
always_comb begin
    if(reset)next_state=`IDLE;
    else if(branch_flush||flush_delay)next_state=`IDLE;
    else if(pause_icache)next_state=current_state;
    else if(current_state==`IDLE)begin
        if(pre_uncache_en)next_state=`UNCACHE_RETURN;
        else if(!pre_valid)next_state=`IDLE;
        else if(a_hit_fail)next_state=`ASKMEM1;
        else if(b_hit_fail)next_state=`ASKMEM2;
        else next_state=`IDLE;
    end
    else if(current_state==`ASKMEM1)begin
        if(real_ret_valid||paused_ret_valid)begin
            if(record_b_hit_result||same_way)next_state=`RETURN;
            else next_state=`ASKMEM2;
        end
        else next_state=`ASKMEM1;
    end
    else if(current_state==`ASKMEM2)begin
        if(real_ret_valid||paused_ret_valid)next_state=`RETURN;
        else next_state=`ASKMEM2;
    end
    else if(current_state==`RETURN)begin
        //if(write_delay)next_state=`RETURN;
        //else next_state=`IDLE;
        next_state=`IDLE;
    end
    else if(current_state==`UNCACHE_RETURN)begin
        if(real_uncache_ret_valid||paused_ret_valid)next_state=`IDLE;
        else next_state=`UNCACHE_RETURN;
    end
    else next_state=`IDLE;
end

always_ff @( posedge clk ) begin
    if(pause_icache)record_b_hit_result<=record_b_hit_result;
    else if(current_state==`IDLE)record_b_hit_result<=b_hit_success;
    else record_b_hit_result<=record_b_hit_result;
end
always_ff @( posedge clk ) begin
    if(pause_icache)record_a_hit_result<=record_a_hit_result;
    else if(current_state==`IDLE)record_a_hit_result<=a_hit_success;
    else record_a_hit_result<=record_a_hit_result;
end


//TLB
assign icache2transaddr.inst_fetch=|(pc2icache.inst_en);
assign icache2transaddr.inst_vaddr=pc2icache.pc;
logic[`ADDR_SIZE-1:0] p_addr_a;
assign p_addr_a=icache2transaddr.ret_inst_paddr;


logic[`ADDR_SIZE-1:0] pre_paddr_a,pre_physical_addr_a,pre_physical_addr_b;
always_ff @( posedge clk ) begin
    if((current_state==`IDLE)&&!pause_icache)pre_paddr_a<=p_addr_a;
    else pre_paddr_a<=pre_paddr_a;
end
assign pre_physical_addr_a=(current_state==`IDLE)?p_addr_a:pre_paddr_a;
assign pre_physical_addr_b=pre_physical_addr_a+32'd4;//当地址转换刚好位于临界值时，可能paddr的tag部分应该不一样！！！！！！！

logic[`ADDR_SIZE-1:0] virtual_addra,virtual_addrb;
assign virtual_addra=pc2icache.pc;
assign virtual_addrb=virtual_addra+`ADDR_SIZE'd4;

logic[`ADDR_SIZE-1:0] pre_vaddr_a,pre_vaddr_b;

assign same_way=(pre_vaddr_a[`TAG_LOC]==pre_vaddr_b[`TAG_LOC])&&(pre_vaddr_a[`INDEX_LOC]==pre_vaddr_b[`INDEX_LOC]);

always_ff @( posedge clk ) begin
    if((next_state==`IDLE)&&!pause_icache)begin
        pre_vaddr_a<=virtual_addra;
        pre_vaddr_b<=virtual_addrb;
    end
    else begin
        pre_vaddr_a<=pre_vaddr_a;
        pre_vaddr_b<=pre_vaddr_b;
    end
end

logic[3:0]wea_way0,wea_way1;
logic[`DATA_SIZE-1:0]data_to_write_way0[`BANK_NUM-1:0];
logic[`DATA_SIZE-1:0]data_to_write_way1[`BANK_NUM-1:0];
logic[`INDEX_SIZE-1:0]addr_way0a,addr_way0b,addr_way1a,addr_way1b;
logic[`DATA_SIZE-1:0]way0_cachea[`BANK_NUM-1:0];
logic[`DATA_SIZE-1:0]way0_cacheb[`BANK_NUM-1:0];
logic[`DATA_SIZE-1:0]way1_cachea[`BANK_NUM-1:0];
logic[`DATA_SIZE-1:0]way1_cacheb[`BANK_NUM-1:0];
generate
    for (genvar i=0;i<`BANK_NUM;i=i+1)begin
        assign data_to_write_way0[i]=real_ret_valid?ret_data[i*`DATA_SIZE+`DATA_SIZE-1:i*`DATA_SIZE]:32'b0;
        assign data_to_write_way1[i]=real_ret_valid?ret_data[i*`DATA_SIZE+`DATA_SIZE-1:i*`DATA_SIZE]:32'b0;
    end
endgenerate

logic[3:0] wea_way0_a,wea_way0_b,wea_way1_a,wea_way1_b;
assign wea_way0_a=(current_state==`ASKMEM1)?wea_way0:4'b0;
assign wea_way0_b=((current_state==`ASKMEM2)||((current_state==`ASKMEM1)&&same_way))?wea_way0:4'b0;
assign wea_way1_a=(current_state==`ASKMEM1)?wea_way1:4'b0;
assign wea_way1_b=((current_state==`ASKMEM2)||((current_state==`ASKMEM1)&&same_way))?wea_way1:4'b0;

assign addr_way0a=((next_state!=`IDLE)||pause_icache)?pre_vaddr_a[`INDEX_LOC]:virtual_addra[`INDEX_LOC];
assign addr_way0b=((next_state!=`IDLE)||pause_icache)?pre_vaddr_b[`INDEX_LOC]:virtual_addrb[`INDEX_LOC];
assign addr_way1a=((next_state!=`IDLE)||pause_icache)?pre_vaddr_a[`INDEX_LOC]:virtual_addra[`INDEX_LOC];
assign addr_way1b=((next_state!=`IDLE)||pause_icache)?pre_vaddr_b[`INDEX_LOC]:virtual_addrb[`INDEX_LOC];



BRAM bank0_way0(.clk(clk),.ena(1'b1),.wea(wea_way0_a),.dina(data_to_write_way0[0]),.addra(addr_way0a),.douta(way0_cachea[0]),.enb(1'b1),.web(wea_way0_b),.dinb(data_to_write_way0[0]),.addrb(addr_way0b),.doutb(way0_cacheb[0]));
BRAM bank1_way0(.clk(clk),.ena(1'b1),.wea(wea_way0_a),.dina(data_to_write_way0[1]),.addra(addr_way0a),.douta(way0_cachea[1]),.enb(1'b1),.web(wea_way0_b),.dinb(data_to_write_way0[1]),.addrb(addr_way0b),.doutb(way0_cacheb[1]));
BRAM bank2_way0(.clk(clk),.ena(1'b1),.wea(wea_way0_a),.dina(data_to_write_way0[2]),.addra(addr_way0a),.douta(way0_cachea[2]),.enb(1'b1),.web(wea_way0_b),.dinb(data_to_write_way0[2]),.addrb(addr_way0b),.doutb(way0_cacheb[2]));
BRAM bank3_way0(.clk(clk),.ena(1'b1),.wea(wea_way0_a),.dina(data_to_write_way0[3]),.addra(addr_way0a),.douta(way0_cachea[3]),.enb(1'b1),.web(wea_way0_b),.dinb(data_to_write_way0[3]),.addrb(addr_way0b),.doutb(way0_cacheb[3]));
BRAM bank4_way0(.clk(clk),.ena(1'b1),.wea(wea_way0_a),.dina(data_to_write_way0[4]),.addra(addr_way0a),.douta(way0_cachea[4]),.enb(1'b1),.web(wea_way0_b),.dinb(data_to_write_way0[4]),.addrb(addr_way0b),.doutb(way0_cacheb[4]));
BRAM bank5_way0(.clk(clk),.ena(1'b1),.wea(wea_way0_a),.dina(data_to_write_way0[5]),.addra(addr_way0a),.douta(way0_cachea[5]),.enb(1'b1),.web(wea_way0_b),.dinb(data_to_write_way0[5]),.addrb(addr_way0b),.doutb(way0_cacheb[5]));
BRAM bank6_way0(.clk(clk),.ena(1'b1),.wea(wea_way0_a),.dina(data_to_write_way0[6]),.addra(addr_way0a),.douta(way0_cachea[6]),.enb(1'b1),.web(wea_way0_b),.dinb(data_to_write_way0[6]),.addrb(addr_way0b),.doutb(way0_cacheb[6]));
BRAM bank7_way0(.clk(clk),.ena(1'b1),.wea(wea_way0_a),.dina(data_to_write_way0[7]),.addra(addr_way0a),.douta(way0_cachea[7]),.enb(1'b1),.web(wea_way0_b),.dinb(data_to_write_way0[7]),.addrb(addr_way0b),.doutb(way0_cacheb[7]));

BRAM bank0_way1(.clk(clk),.ena(1'b1),.wea(wea_way1_a),.dina(data_to_write_way1[0]),.addra(addr_way1a),.douta(way1_cachea[0]),.enb(1'b1),.web(wea_way1_b),.dinb(data_to_write_way1[0]),.addrb(addr_way1b),.doutb(way1_cacheb[0]));
BRAM bank1_way1(.clk(clk),.ena(1'b1),.wea(wea_way1_a),.dina(data_to_write_way1[1]),.addra(addr_way1a),.douta(way1_cachea[1]),.enb(1'b1),.web(wea_way1_b),.dinb(data_to_write_way1[1]),.addrb(addr_way1b),.doutb(way1_cacheb[1]));
BRAM bank2_way1(.clk(clk),.ena(1'b1),.wea(wea_way1_a),.dina(data_to_write_way1[2]),.addra(addr_way1a),.douta(way1_cachea[2]),.enb(1'b1),.web(wea_way1_b),.dinb(data_to_write_way1[2]),.addrb(addr_way1b),.doutb(way1_cacheb[2]));
BRAM bank3_way1(.clk(clk),.ena(1'b1),.wea(wea_way1_a),.dina(data_to_write_way1[3]),.addra(addr_way1a),.douta(way1_cachea[3]),.enb(1'b1),.web(wea_way1_b),.dinb(data_to_write_way1[3]),.addrb(addr_way1b),.doutb(way1_cacheb[3]));
BRAM bank4_way1(.clk(clk),.ena(1'b1),.wea(wea_way1_a),.dina(data_to_write_way1[4]),.addra(addr_way1a),.douta(way1_cachea[4]),.enb(1'b1),.web(wea_way1_b),.dinb(data_to_write_way1[4]),.addrb(addr_way1b),.doutb(way1_cacheb[4]));
BRAM bank5_way1(.clk(clk),.ena(1'b1),.wea(wea_way1_a),.dina(data_to_write_way1[5]),.addra(addr_way1a),.douta(way1_cachea[5]),.enb(1'b1),.web(wea_way1_b),.dinb(data_to_write_way1[5]),.addrb(addr_way1b),.doutb(way1_cacheb[5]));
BRAM bank6_way1(.clk(clk),.ena(1'b1),.wea(wea_way1_a),.dina(data_to_write_way1[6]),.addra(addr_way1a),.douta(way1_cachea[6]),.enb(1'b1),.web(wea_way1_b),.dinb(data_to_write_way1[6]),.addrb(addr_way1b),.doutb(way1_cacheb[6]));
BRAM bank7_way1(.clk(clk),.ena(1'b1),.wea(wea_way1_a),.dina(data_to_write_way1[7]),.addra(addr_way1a),.douta(way1_cachea[7]),.enb(1'b1),.web(wea_way1_b),.dinb(data_to_write_way1[7]),.addrb(addr_way1b),.doutb(way1_cacheb[7]));

logic [`DATA_SIZE-1:0]data_to_write_tagv0,data_to_write_tagv1;
logic [`TAG_SIZE-1:0]tag_to_write_tagv;
assign tag_to_write_tagv=(current_state==`ASKMEM1)?pre_vaddr_a[`TAG_LOC]:pre_vaddr_b[`TAG_LOC];
assign data_to_write_tagv0={11'b0,1'b1,tag_to_write_tagv};
assign data_to_write_tagv1={11'b0,1'b1,tag_to_write_tagv};
logic [`DATA_SIZE-1:0]way0_tagva,way0_tagvb,way1_tagva,way1_tagvb;
BRAM tagv0(.clk(clk),.ena(1'b1),.wea(wea_way0_a),.dina(data_to_write_tagv0),.addra(addr_way0a),.douta(way0_tagva),.enb(1'b1),.web(wea_way0_b),.dinb(data_to_write_tagv0),.addrb(addr_way0b),.doutb(way0_tagvb));
BRAM tagv1(.clk(clk),.ena(1'b1),.wea(wea_way1_a),.dina(data_to_write_tagv1),.addra(addr_way1a),.douta(way1_tagva),.enb(1'b1),.web(wea_way1_b),.dinb(data_to_write_tagv1),.addrb(addr_way1b),.doutb(way1_tagvb));

logic a_hit_way0,a_hit_way1,b_hit_way0,b_hit_way1;
assign a_hit_way0=way0_tagva[19:0]==pre_vaddr_a[`TAG_LOC]&&way0_tagva[20]==1'b1;
assign a_hit_way1=way1_tagva[19:0]==pre_vaddr_a[`TAG_LOC]&&way1_tagva[20]==1'b1;
assign b_hit_way0=way0_tagvb[19:0]==pre_vaddr_b[`TAG_LOC]&&way0_tagvb[20]==1'b1;
assign b_hit_way1=way1_tagvb[19:0]==pre_vaddr_b[`TAG_LOC]&&way1_tagvb[20]==1'b1;

assign a_hit_success=pre_valid&&(a_hit_way0||a_hit_way1);
assign b_hit_success=pre_valid&&(b_hit_way0||b_hit_way1);
assign a_hit_fail=pre_valid&&(!a_hit_success);
assign b_hit_fail=pre_valid&&(!b_hit_success);


logic read_success;
always_ff @( posedge clk ) begin
    if(real_ret_valid)read_success<=1'b1;
    else read_success<=1'b0;
end
//LRU
logic [`SET_SIZE-1:0]LRU;
always_ff @( posedge clk ) begin//这块没有完全用else-if了！！！！！！！！！！！！！！！！！！！！！！！
    if(reset)LRU<=0;
    else begin
        if(a_hit_success)LRU[pre_physical_addr_a[`INDEX_LOC]] <= a_hit_way0;
        if(b_hit_success)LRU[pre_physical_addr_b[`INDEX_LOC]] <= b_hit_way0;
        else begin
            if(record_a_hit_result==1'b0&&read_success)LRU[pre_physical_addr_a[`INDEX_LOC]] <= |wea_way0;
            else LRU<=LRU;
        end
    end
end
logic[`INDEX_SIZE-1:0]replace_index;
assign replace_index=(current_state==`ASKMEM1)?pre_physical_addr_a[`INDEX_LOC]:((current_state==`ASKMEM2)?pre_physical_addr_b[`INDEX_LOC]:`INDEX_SIZE'b1111111);
logic LRU_pick;
assign LRU_pick=LRU[replace_index];


assign wea_way0=(pre_valid&&real_ret_valid&&LRU_pick==1'b0)?4'b1111:4'b0000;
assign wea_way1=(pre_valid&&real_ret_valid&&LRU_pick==1'b1)?4'b1111:4'b0000;



assign rd_req=((current_state==`ASKMEM1)||(current_state==`ASKMEM2))&&!paused_ret_valid&&!ret_valid;
assign rd_addr=(current_state==`ASKMEM1)?pre_physical_addr_a:pre_physical_addr_b;



assign pc2icache.stall=(next_state!=`IDLE)||pause_icache;
assign pc2icache.inst[0]=(current_state==`UNCACHE_RETURN)?iucache_rdata_o:
                            ((flush_delay||branch_flush)?32'b0:
                                (a_hit_success?(a_hit_way0?way0_cachea[pre_vaddr_a[4:2]]:way1_cachea[pre_vaddr_a[4:2]]):32'b0));//uncache情况下用inst[0]返回
assign pc2icache.inst[1]=(flush_delay||branch_flush)?32'b0:(b_hit_success?(b_hit_way0?way0_cacheb[pre_vaddr_b[4:2]]:way1_cacheb[pre_vaddr_b[4:2]]):32'b0);
assign pc2icache.pc_for_bpu[0]=branch_flush?32'b0:pre_vaddr_a;
assign pc2icache.pc_for_bpu[1]=branch_flush?32'b0:((current_state==`UNCACHE_RETURN)?(`DATA_SIZE'b0): pre_vaddr_b);


logic[`ADDR_SIZE-1:0] record_uncache_pc;
always_ff @( posedge clk ) begin
    if(pc2icache.uncache_en&&(next_state==`IDLE))record_uncache_pc<=pc2icache.pc;
    else record_uncache_pc<=record_uncache_pc;
end
assign iucache_ren_i=(!flush_delay)&&(!branch_flush)&&(((current_state==`IDLE)&&pc2icache.uncache_en)||(current_state==`UNCACHE_RETURN));
assign iucache_addr_i=record_uncache_pc;//uncache模式直接用的虚拟地址，不知道对不对

assign flush=branch_flush;

always_ff @(posedge clk) begin
    if (reset | branch_flush) begin
        pc2icache.pc_for_buffer <= 0;
        pc2icache.stall_for_buffer <= 0;
        pc2icache.inst_for_buffer <= 0;
        pc2icache.icache_is_exception <= 0;
        pc2icache.icache_exception_cause <= 0;
        pc2icache.icache_fetch_inst_en <= 0;
    end
    else begin
        pc2icache.pc_for_buffer <= pc2icache.pc_for_bpu;
        pc2icache.stall_for_buffer <= pc2icache.stall;
        pc2icache.inst_for_buffer <= pc2icache.inst;
        pc2icache.icache_is_exception <= {2{pc2icache.front_is_exception}};
        pc2icache.icache_exception_cause <= {2{pc2icache.front_exception_cause}};
        pc2icache.icache_fetch_inst_en <= pc2icache.front_fetch_inst_en;
    end
end

endmodule