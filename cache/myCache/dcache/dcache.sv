typedef logic[31:0] bus32_t;
typedef logic[255:0] bus256_t;

typedef struct packed {
    logic is_cacop;
    logic[4:0]cacop_code;
    logic is_preld;
    logic hint;
    bus32_t addr;
}cache_inst_t;

    interface mem_dcache;
        logic valid;                // 请求有效
        logic op;                   // 操作类型，读-0，写-1
        logic[2:0] size;           // 数据大小，3'b000--字节，3'b001--半字，3'b010--字
        logic[31:0] virtual_addr;   // 虚拟地址
        logic tlb_excp_cancel_req;
        logic[3:0]  wstrb;          //写使能，1表示对应的8位数据需要写
        logic[31:0] wdata;          //需要写的数据
        
        logic addr_ok;              //该次请求的地址传输OK，读：地址被接收；写：地址和数据被接收
        logic data_ok;              //该次请求的数据传输OK，读：数据返回；写：数据写入完成
        logic[31:0] rdata;          //读DCache的结果
        logic cache_miss;           //cache未命中

        modport master (
            input addr_ok, data_ok, rdata, cache_miss,
            output valid, op, size, virtual_addr, tlb_excp_cancel_req, wstrb, wdata
        );

        modport slave (
            output addr_ok, data_ok, rdata, cache_miss,
            input valid, op, size, virtual_addr, tlb_excp_cancel_req, wstrb, wdata
        );
    endinterface: mem_dcache



interface dcache_transaddr;
    logic                   data_fetch;    //指令地址转换信息有效的信号assign fetch_en  = inst_valid && inst_addr_ok;
    logic [31:0]            data_vaddr;    //虚拟地址
    logic [31:0]            ret_data_paddr;//物理地址

    modport master(
        input ret_data_paddr,
        output data_fetch,data_vaddr  
    );

    modport slave(
        output ret_data_paddr,
        input data_fetch,data_vaddr
    );
endinterface : dcache_transaddr

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

`define IDLE 5'b00001
`define WRITE_DIRTY 5'b00010
`define ASKMEM 5'b00100
`define RETURN 5'b01000
`define UNCACHE_RETURN 5'b10000



module dcache (
    input logic clk,
    input logic reset,
    //to cpu
    mem_dcache mem2dcache,//读写数据的信号
    input logic dcache_uncache,//uncache使能信号
    input cache_inst_t dcache_inst,//dcache指令信号

    //to transaddr
    dcache_transaddr dcache2transaddr,//TLB地址转换

    //to axi
    output logic rd_req,//读请求有效
    output logic[2:0] rd_type,//3'b000--字节，3'b001--半字，3'b010--字，3'b100--Cache行。
    output bus32_t rd_addr,//要读的数据所在的物理地址
    output logic       wr_req,//写请求有效
    output logic[31:0] wr_addr,//要写的数据所在的物理地址
    output logic[3:0]  wr_wstrb,//4位的写使能信号，决定4个8位中，每个8位是否要写入
    output bus256_t wr_data,//8个32位的数据为1路

    input logic       wr_rdy,//能接收写操作
    input logic       data_bvalid_o,//写完成
    input logic       rd_rdy,//能接收读操作
    input logic       ret_valid,//返回数据信号有效
    input bus256_t ret_data,//返回的数据
    //uncache
    output logic ducache_ren_i,
    output bus32_t ducache_araddr_i,
    input logic ducache_rvalid_o,
    input bus32_t ducache_rdata_o,

    output logic ducache_wen_i,
    output bus32_t ducache_wdata_i,
    output bus32_t ducache_awaddr_i,
    output logic[3:0]ducache_strb,//改了个名
    input logic ducache_bvalid_o

);

logic read_success;
always_ff @( posedge clk ) begin
    if(ret_valid)read_success<=1'b1;
    else read_success<=1'b0;
end

logic[4:0]current_state,next_state;

logic pre_valid,pre_op;
logic[3:0]pre_wstrb;
logic[`DATA_SIZE-1:0]pre_wdata;
logic[`ADDR_SIZE-1:0]pre_vaddr;
always_ff @( posedge clk ) begin
    if((current_state==`IDLE)&&(next_state==`UNCACHE_RETURN))begin
        pre_valid<=mem2dcache.valid;
        pre_op<=mem2dcache.op;
        pre_wstrb<=mem2dcache.wstrb;
        pre_wdata<=mem2dcache.wdata;
        pre_vaddr<=mem2dcache.virtual_addr;
    end
    else if(next_state==`IDLE)begin
        pre_valid<=mem2dcache.valid;
        pre_op<=mem2dcache.op;
        pre_wstrb<=mem2dcache.wstrb;
        pre_wdata<=mem2dcache.wdata;
        pre_vaddr<=mem2dcache.virtual_addr;
    end
    else begin
        pre_valid<=pre_valid;
        pre_op<=pre_op;
        pre_wstrb<=pre_wstrb;
        pre_wdata<=pre_wdata;
        pre_vaddr<=pre_vaddr;
    end
end


logic hit_success,hit_fail;
logic write_dirty;



always_ff @( posedge clk ) begin
    if(reset)current_state<=`IDLE;
    else current_state<=next_state;
end
always_comb begin
    if(reset)next_state=`IDLE;
    else if(current_state==`IDLE)begin
        if(!pre_valid)next_state=`IDLE;
        else if(dcache_uncache)next_state=`UNCACHE_RETURN;
        else if(hit_fail)begin
            if(write_dirty&&!wr_rdy)next_state=`WRITE_DIRTY;
            else next_state=`ASKMEM;
        end
        else next_state=`IDLE;
    end
    else if(current_state==`WRITE_DIRTY)begin
        if(wr_rdy)next_state=`ASKMEM;
        else next_state=`WRITE_DIRTY;
    end
    else if(current_state==`ASKMEM)begin
        if(ret_valid)next_state=`RETURN;
        else next_state=`ASKMEM;
    end
    else if(current_state==`RETURN)begin
        next_state=`IDLE;
    end
    else if(current_state==`UNCACHE_RETURN)begin
        if(pre_op==1'b1&&wr_rdy)next_state=`IDLE;
        else if(pre_op==1'b0&&ducache_rvalid_o)next_state=`IDLE;
        else next_state=`UNCACHE_RETURN;
    end
end

//TLB
assign dcache2transaddr.data_fetch=mem2dcache.valid;
assign dcache2transaddr.data_vaddr=mem2dcache.virtual_addr;
logic[`ADDR_SIZE-1:0] p_addr,pre_physical_addr,target_physical_addr;
assign p_addr=dcache2transaddr.ret_data_paddr;
always_ff @( posedge clk ) begin
    if(current_state==`IDLE)pre_physical_addr<=p_addr;
    else pre_physical_addr<=pre_physical_addr;
end
assign target_physical_addr=(current_state==`IDLE)?p_addr:pre_physical_addr;


logic write_read_same;
assign write_read_same=(pre_valid&&pre_op==1'b1)&&(mem2dcache.valid&&mem2dcache.op==1'b0)&&(pre_vaddr[31:5]==mem2dcache.virtual_addr[31:5]);










logic [`DATA_SIZE-1:0]read_from_mem[`BANK_NUM-1:0];
for(genvar i =0 ;i<`BANK_NUM; i=i+1)begin
	assign read_from_mem[i] = ret_data[32*(i+1)-1:32*i];
end
logic hit_way0,hit_way1;

reg [`DATA_SIZE-1:0]cache_wdata[`BANK_NUM-1:0];


logic [3:0]wea_way0;
logic [3:0]wea_way1;
logic [3:0]wea_way0_single[7:0];
logic [3:0]wea_way1_single[7:0];

for(genvar i=0;i<8;i=i+1)begin
    assign wea_way0_single[i]=(pre_valid&&hit_way0&&pre_op==1'b1&&i!=pre_vaddr[4:2])?4'b0000:wea_way0;
    assign wea_way1_single[i]=(pre_valid&&hit_way1&&pre_op==1'b1&&i!=pre_vaddr[4:2])?4'b0000:wea_way1;
end


logic [`DATA_SIZE-1:0]way0_cache[`BANK_NUM-1:0];
logic [`DATA_SIZE-1:0]way0_cache_b[`BANK_NUM-1:0];
logic [6:0] read_index_addr,write_index_addr;
assign read_index_addr = (next_state==`IDLE)?mem2dcache.virtual_addr[`INDEX_LOC]:pre_vaddr[`INDEX_LOC];
assign write_index_addr=pre_vaddr[`INDEX_LOC];

logic [6:0] way0_index_addr;
logic [6:0] way1_index_addr;
assign way0_index_addr=|wea_way0?write_index_addr:read_index_addr;
assign way1_index_addr=|wea_way1?write_index_addr:read_index_addr;

BRAM Bank0_way0(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way0_cache[0]),.enb(1'b1),.web(wea_way0_single[0]),.dinb(cache_wdata[0]),.addrb(write_index_addr),.doutb(way0_cache_b[0]));
BRAM Bank1_way0(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way0_cache[1]),.enb(1'b1),.web(wea_way0_single[1]),.dinb(cache_wdata[1]),.addrb(write_index_addr),.doutb(way0_cache_b[1]));
BRAM Bank2_way0(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way0_cache[2]),.enb(1'b1),.web(wea_way0_single[2]),.dinb(cache_wdata[2]),.addrb(write_index_addr),.doutb(way0_cache_b[2]));
BRAM Bank3_way0(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way0_cache[3]),.enb(1'b1),.web(wea_way0_single[3]),.dinb(cache_wdata[3]),.addrb(write_index_addr),.doutb(way0_cache_b[3]));
BRAM Bank4_way0(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way0_cache[4]),.enb(1'b1),.web(wea_way0_single[4]),.dinb(cache_wdata[4]),.addrb(write_index_addr),.doutb(way0_cache_b[4]));
BRAM Bank5_way0(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way0_cache[5]),.enb(1'b1),.web(wea_way0_single[5]),.dinb(cache_wdata[5]),.addrb(write_index_addr),.doutb(way0_cache_b[5]));
BRAM Bank6_way0(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way0_cache[6]),.enb(1'b1),.web(wea_way0_single[6]),.dinb(cache_wdata[6]),.addrb(write_index_addr),.doutb(way0_cache_b[6]));
BRAM Bank7_way0(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way0_cache[7]),.enb(1'b1),.web(wea_way0_single[7]),.dinb(cache_wdata[7]),.addrb(write_index_addr),.doutb(way0_cache_b[7]));

 
logic [`DATA_SIZE-1:0]way1_cache[`BANK_NUM-1:0];
logic [`DATA_SIZE-1:0]way1_cache_b[`BANK_NUM-1:0];  

BRAM Bank0_way1(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way1_cache[0]),.enb(1'b1),.web(wea_way1_single[0]),.dinb(cache_wdata[0]),.addrb(write_index_addr),.doutb(way1_cache_b[0]));
BRAM Bank1_way1(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way1_cache[1]),.enb(1'b1),.web(wea_way1_single[1]),.dinb(cache_wdata[1]),.addrb(write_index_addr),.doutb(way1_cache_b[1]));
BRAM Bank2_way1(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way1_cache[2]),.enb(1'b1),.web(wea_way1_single[2]),.dinb(cache_wdata[2]),.addrb(write_index_addr),.doutb(way1_cache_b[2]));
BRAM Bank3_way1(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way1_cache[3]),.enb(1'b1),.web(wea_way1_single[3]),.dinb(cache_wdata[3]),.addrb(write_index_addr),.doutb(way1_cache_b[3]));
BRAM Bank4_way1(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way1_cache[4]),.enb(1'b1),.web(wea_way1_single[4]),.dinb(cache_wdata[4]),.addrb(write_index_addr),.doutb(way1_cache_b[4]));
BRAM Bank5_way1(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way1_cache[5]),.enb(1'b1),.web(wea_way1_single[5]),.dinb(cache_wdata[5]),.addrb(write_index_addr),.doutb(way1_cache_b[5]));
BRAM Bank6_way1(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way1_cache[6]),.enb(1'b1),.web(wea_way1_single[6]),.dinb(cache_wdata[6]),.addrb(write_index_addr),.doutb(way1_cache_b[6]));
BRAM Bank7_way1(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(way1_cache[7]),.enb(1'b1),.web(wea_way1_single[7]),.dinb(cache_wdata[7]),.addrb(write_index_addr),.doutb(way1_cache_b[7]));


//Tag1'b1
logic [`TAGV_SIZE-1:0]tagv_cache_w0;
logic [`TAGV_SIZE-1:0]tagv_cache_w1;
logic [`TAGV_SIZE-1:0]tagv_cache_w0_a;//改了！！！！！！！！！！！！！！！！！！！！！！！！！！！！！
logic [`TAGV_SIZE-1:0]tagv_cache_w1_a;
logic [`TAGV_SIZE-1:0]tagv_cache_w0_b;
logic [`TAGV_SIZE-1:0]tagv_cache_w1_b;
assign tagv_cache_w0=write_read_same?tagv_cache_w0_b:tagv_cache_w0_a;
assign tagv_cache_w1=write_read_same?tagv_cache_w1_b:tagv_cache_w1_a;

logic[`INDEX_SIZE-1:0] tagv_addr_write;
assign tagv_addr_write=pre_vaddr[`INDEX_LOC];
logic[`TAGV_SIZE-1:0]tagv_data_tagv;
assign tagv_data_tagv={1'b1,pre_vaddr[`TAG_LOC]};

logic[`INDEX_SIZE-1:0]tagv0_addr,tagv1_addr;
assign tagv0_addr=|wea_way0?tagv_addr_write:read_index_addr;
assign tagv1_addr=|wea_way1?tagv_addr_write:read_index_addr;

BRAM TagV0(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(tagv_cache_w0_a),.enb(1'b1),.web(wea_way0),.dinb(tagv_data_tagv),.addrb(tagv_addr_write),.doutb(tagv_cache_w0_b));
BRAM TagV1(.clk(clk),.ena(1'b1),.wea(4'b0),.dina(32'b0),.addra(read_index_addr),.douta(tagv_cache_w1_a),.enb(1'b1),.web(wea_way1),.dinb(tagv_data_tagv),.addrb(tagv_addr_write),.doutb(tagv_cache_w1_b));


logic[31:0] write_mask;
assign write_mask={{8{pre_wstrb[3]}},{8{pre_wstrb[2]}},{8{pre_wstrb[1]}},{8{pre_wstrb[0]}}};


always_comb begin 
	if(hit_fail&&ret_valid)begin
        if(pre_op==1'b1)begin
            cache_wdata=read_from_mem;
            cache_wdata[pre_vaddr[4:2]]=(pre_wdata & write_mask)|(read_from_mem[pre_vaddr[4:2]] & ~write_mask);
        end
        else begin
            cache_wdata=read_from_mem;
        end
        
	end
	else if(hit_success&&pre_op==1'b1)begin
        if(hit_way0)cache_wdata=way0_cache;
        else if(hit_way1)cache_wdata=way1_cache;
        else cache_wdata='{default:0};
        cache_wdata[pre_vaddr[4:2]]=(pre_wdata & write_mask)|(((hit_way0)?way0_cache[pre_vaddr[4:2]]:way1_cache[pre_vaddr[4:2]]) & ~write_mask);
	end
    else begin
        cache_wdata='{default:0};
    end
end



//LRU
logic [`SET_SIZE-1:0]LRU;
logic LRU_pick;
assign LRU_pick = LRU[pre_vaddr[`INDEX_LOC]];
always_ff @( posedge clk ) begin
    if(reset)LRU<=0;
    else if(pre_valid&&hit_success)LRU[pre_vaddr[`INDEX_LOC]] <= hit_way0;
    else if(pre_valid&&hit_fail&&read_success)LRU[pre_vaddr[`INDEX_LOC]] <= wea_way0;
    else LRU<=LRU;
end


//判断命中
assign hit_way0 = (tagv_cache_w0[19:0]==target_physical_addr[`TAG_LOC] && tagv_cache_w0[20]==1'b1)? 1'b1 : 1'b0;
assign hit_way1 = (tagv_cache_w1[19:0]==target_physical_addr[`TAG_LOC] && tagv_cache_w1[20]==1'b1)? 1'b1 : 1'b0;
assign hit_success = (hit_way0 | hit_way1) & pre_valid;
assign hit_fail = ~(hit_success) & pre_valid;


assign wea_way0=(pre_valid&&hit_way0&&pre_op==1'b1)?pre_wstrb:((pre_valid&&ret_valid&&LRU_pick==1'b0)?4'b1111:4'b0000);
assign wea_way1=(pre_valid&&hit_way1&&pre_op==1'b1)?pre_wstrb:((pre_valid&&ret_valid&&LRU_pick==1'b1)?4'b1111:4'b0000);




//Dirty
    reg [`SET_SIZE*2-1:0] dirty;
	assign write_dirty = dirty[{pre_vaddr[`INDEX_LOC],LRU_pick}]; 
    always@(posedge clk)begin
        if(reset)
            dirty<=0;
		else if(ret_valid == 1'b1 && pre_op == 1'b0)//Read not hit
            dirty[{pre_vaddr[`INDEX_LOC],LRU_pick}] <= 1'b0;
		else if(ret_valid == 1'b1 && pre_op == 1'b1)//write not hit
            dirty[{pre_vaddr[`INDEX_LOC],LRU_pick}] <= 1'b1;
		else if((hit_way0|hit_way1) == 1'b1 && pre_op == 1'b1)//write hit but not FIFO
            dirty[{pre_vaddr[`INDEX_LOC],hit_way1}] <= 1'b1;
        else
            dirty <= dirty;
    end





assign mem2dcache.addr_ok=mem2dcache.valid&&((next_state==`IDLE)||((current_state==`IDLE)&&(next_state==`UNCACHE_RETURN)));
assign mem2dcache.data_ok=((next_state==`IDLE)||(current_state==`IDLE)&&(next_state==`UNCACHE_RETURN))&&pre_valid&&pre_op==1'b0;
assign mem2dcache.rdata=(current_state==`UNCACHE_RETURN)?ducache_rdata_o:
                            (hit_success?
                                    (hit_way0?(write_read_same?way0_cache_b[pre_vaddr[4:2]]:way0_cache[pre_vaddr[4:2]]):
                                    (write_read_same?way1_cache_b[pre_vaddr[4:2]]:way1_cache[pre_vaddr[4:2]])):
                                            read_from_mem[pre_vaddr[4:2]]);
assign mem2dcache.cache_miss=hit_fail;



assign rd_req=(next_state==`ASKMEM)||(current_state==`ASKMEM);
assign rd_type=3'b100;
assign rd_addr=target_physical_addr;


//写脏数据
logic record_write_mem_en;
always_ff @( posedge clk ) begin
    if(reset)record_write_mem_en<=1'b0;
    else if(data_bvalid_o)record_write_mem_en<=1'b0;
    else if((current_state==`IDLE)&&hit_fail&&write_dirty)record_write_mem_en<=1'b1;
    else record_write_mem_en<=record_write_mem_en;
end
logic[31:0] record_write_mem_addr;
logic[255:0] record_write_mem_data;
always_ff @( posedge clk ) begin
    if(reset)begin
        record_write_mem_addr<=32'b0;
        record_write_mem_data<=256'b0;
    end
    else if((current_state==`IDLE)&&hit_fail&&write_dirty)begin
        record_write_mem_addr<=p_addr;
        record_write_mem_data<=LRU_pick?{way1_cache[7],way1_cache[6],way1_cache[5],way1_cache[4],way1_cache[3],way1_cache[2],way1_cache[1],way1_cache[0]}:{way0_cache[7],way0_cache[6],way0_cache[5],way0_cache[4],way0_cache[3],way0_cache[2],way0_cache[1],way0_cache[0]};
    end
    else begin
        record_write_mem_addr<=record_write_mem_addr;
        record_write_mem_data<=record_write_mem_data;
    end
end
assign wr_req=record_write_mem_en&&!data_bvalid_o;
assign wr_addr=record_write_mem_addr;
assign wr_data=record_write_mem_data;
assign wstrb=4'b1111;




assign ducache_ren_i=(current_state==`UNCACHE_RETURN)&&pre_op==1'b0;
assign ducache_wen_i=(current_state==`UNCACHE_RETURN)&&pre_op==1'b1;
assign ducache_araddr_i=ducache_ren_i?pre_vaddr:32'b0;
assign ducache_awaddr_i=ducache_wen_i?pre_vaddr:32'b0;
assign ducache_wdata_i=ducache_wen_i?pre_wdata:32'b0;
assign ducache_strb=ducache_wen_i?pre_wstrb:4'b0;


always_ff @( posedge clk ) begin
    if(((current_state==`IDLE)&&(next_state==`UNCACHE_RETURN))&&mem2dcache.op==1'b1)begin
        ducache_wen_i<=1'b1;
        ducache_awaddr_i<=mem2dcache.virtual_addr;
        ducache_wdata_i<=mem2dcache.wdata;
        ducache_strb<=mem2dcache.wstrb;
    end
    else if((current_state==`UNCACHE_RETURN)&&(pre_op==1'b1)&&ducache_bvalid_o)begin
        ducache_wen_i<=1'b0;
    end
    else begin
        ducache_wen_i<=ducache_wen_i;
        ducache_awaddr_i<=ducache_awaddr_i;
        ducache_wdata_i<=ducache_wdata_i;
        ducache_strb<=ducache_strb;
    end
end




endmodule
