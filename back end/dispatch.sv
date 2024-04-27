`include "defines.sv"

module dispatch 
    import pipeline_types::*;
(
    input id_dispatch_t id_dispatch,
    input pipeline_push_forward_t ex_push_forward,
    input pipeline_push_forward_t mem_push_forward,

    input alu_op_t ex_aluop,

    dispatch_regfile master,

    output logic pause_dispatch,
    output dispatch_ex_t dispatch_ex,

    output bus32_t branch_target_addr_actual,
    output logic branch_flush
);
    assign dispatch_ex.pc = id_dispatch.pc; 
    assign dispatch_ex.inst = id_dispatch.inst;
    assign dispatch_ex.cacop_code = id_dispatch.cacop_code;

    assign dispatch_ex.is_exception = id_dispatch.is_exception;
    assign dispatch_ex.exception_cause = id_dispatch.exception_cause;

    assign dispatch_ex.aluop = id_dispatch.aluop;
    assign dispatch_ex.alusel = id_dispatch.alusel;

    assign dispatch_ex.reg_write_en = id_dispatch.reg_write_en;
    assign dispatch_ex.reg_write_addr = id_dispatch.reg_write_addr;
    
    assign dispatch_ex.csr_read_en = id_dispatch.csr_read_en;
    assign dispatch_ex.csr_write_en = id_dispatch.csr_write_en;
    assign dispatch_ex.csr_addr = id_dispatch.csr_addr;

    assign master.reg1_read_en = id_dispatch.reg1_read_en;
    assign master.reg1_read_addr = id_dispatch.reg1_read_addr;
    assign master.reg2_read_en = id_dispatch.reg2_read_en;
    assign master.reg2_read_addr = id_dispatch.reg2_read_addr;

    bus32_t branch16_addr;
    bus32_t branch26_addr;

    assign branch16_addr = {{14{id_dispatch.inst[25]}}, id_dispatch.inst[25: 10], 2'b00};
    assign branch26_addr = {{4{id_dispatch.inst[9]}}, id_dispatch.inst[9: 0], id_dispatch.inst[25: 10], 2'b00};

    logic pause_reg1_load_relate;
    logic pause_reg2_load_relate;
    logic load_pre;

    assign load_pre = ((ex_aluop == `ALU_LDB) || (ex_aluop == `ALU_LDH) || (ex_aluop == `ALU_LDW) 
                    || (ex_aluop == `ALU_LDBU) || (ex_aluop == `ALU_LDHU) || (ex_aluop == `ALU_LLW)
                    || (ex_aluop == `ALU_SCW)) ? 1'b1 : 1'b0;

    assign pause_reg1_load_relate = (load_pre && (ex_push_forward.reg_write_addr == id_dispatch.reg1_read_addr) && id_dispatch.reg1_read_en) ? 1'b1 : 1'b0;
    assign pause_reg2_load_relate = (load_pre && (ex_push_forward.reg_write_addr == id_dispatch.reg2_read_addr) && id_dispatch.reg2_read_en) ? 1'b1 : 1'b0;

    assign pause_dispatch = pause_reg1_load_relate || pause_reg2_load_relate;

    logic reg1_lt_reg2;

    bus32_t branch_target_addr;
    logic is_branch;

    // branch
    always_comb begin : branch
        is_branch = 1'b0;
        branch_target_addr = 32'b0;
        branch_flush = 1'b0;
        dispatch_ex.reg_write_branch_data = 32'b0;
        branch_target_addr_actual = 32'b0;

        reg1_lt_reg2 = (dispatch_ex.reg1[31] && !dispatch_ex.reg2[31]) || (!dispatch_ex.reg1[31] && !dispatch_ex.reg2[31] && (dispatch_ex.reg1 < dispatch_ex.reg2)) 
                                    || (dispatch_ex.reg1[31] && dispatch_ex.reg2[31] && (dispatch_ex.reg1 > dispatch_ex.reg2));

        if (is_branch && id_dispatch.pre_is_branch_taken) begin
            if (id_dispatch.pre_branch_addr == branch_target_addr) begin
                branch_flush = 1'b0;
            end
            else begin
                branch_flush = 1'b1;
                branch_target_addr_actual = branch_target_addr;
            end
        end
        else if (!is_branch && id_dispatch.pre_is_branch_taken) begin
            branch_flush = 1'b1;
            branch_target_addr_actual = id_dispatch.pc + 4'h4;
        end
        else begin
            branch_flush = 1'b0;
        end

        case (id_dispatch.aluop) 
            `ALU_BEQ: begin
                if (dispatch_ex.reg1 == dispatch_ex.reg2) begin
                    is_branch = 1'b1;
                    branch_target_addr = id_dispatch.pc + branch16_addr;
                end
            end
            `ALU_BNE: begin
                if (dispatch_ex.reg1 != dispatch_ex.reg2) begin
                    is_branch = 1'b1;
                    branch_target_addr = id_dispatch.pc + branch16_addr;
                end
            end
            `ALU_BLT, `ALU_BLTU: begin
                if (reg1_lt_reg2) begin
                    is_branch = 1'b1;
                    branch_target_addr = id_dispatch.pc + branch16_addr;
                end
            end
            `ALU_BGE, `ALU_BGEU: begin
                if (!reg1_lt_reg2) begin
                    is_branch = 1'b1;
                    branch_target_addr = id_dispatch.pc + branch16_addr;
                end
            end
            `ALU_B: begin
                is_branch = 1'b1;
                branch_target_addr = id_dispatch.pc + branch26_addr;
            end
            `ALU_BL, `ALU_JIRL: begin
                is_branch = 1'b1;
                branch_target_addr = id_dispatch.pc + branch26_addr;
                dispatch_ex.reg_write_branch_data = id_dispatch.pc + 4'h4;
            end
            `ALU_JIRL: begin
                is_branch = 1'b1;
                branch_target_addr = dispatch_ex.reg1 + branch26_addr;
                dispatch_ex.reg_write_branch_data = id_dispatch.pc + 4'h4;
            end
        endcase
    end

    always_comb begin : reg1_read
        if (pause_dispatch) begin
            dispatch_ex.reg1 = 32'b0;
        end 
        else if (id_dispatch.reg1_read_en && (id_dispatch.aluop == `ALU_PCADDU12I)) begin
            dispatch_ex.reg1 = id_dispatch.pc;
        end
        else if (id_dispatch.reg1_read_en && ex_push_forward.reg_write_en && (ex_push_forward.reg_write_addr == id_dispatch.reg1_read_addr)) begin
            dispatch_ex.reg1 = ex_push_forward.reg_write_data;
        end
        else if (id_dispatch.reg1_read_en && mem_push_forward.reg_write_en && (mem_push_forward.reg_write_addr == id_dispatch.reg1_read_addr)) begin
            dispatch_ex.reg1 = mem_push_forward.reg_write_data;
        end
        else if (id_dispatch.reg1_read_en) begin
            dispatch_ex.reg1 = master.reg1_read_data;
        end 
        else if (!id_dispatch.reg1_read_en) begin
            dispatch_ex.reg1 = id_dispatch.imm;
        end
        else begin
            dispatch_ex.reg1 = 32'b0;
        end
    end

    always_comb begin : reg2_read
        if (pause_dispatch) begin
            dispatch_ex.reg2 = 32'b0;
        end 
        else if (id_dispatch.reg2_read_en && ex_push_forward.reg_write_en&& (ex_push_forward.reg_write_addr == id_dispatch.reg2_read_addr)) begin
            dispatch_ex.reg2 = ex_push_forward.reg_write_data;
        end
        else if (id_dispatch.reg2_read_en && mem_push_forward.reg_write_en && (mem_push_forward.reg_write_addr == id_dispatch.reg2_read_addr)) begin
            dispatch_ex.reg2 = mem_push_forward.reg_write_data;
        end
        else if (id_dispatch.reg2_read_en) begin
            dispatch_ex.reg2 = master.reg2_read_data;
        end
        else if (!id_dispatch.reg2_read_en) begin
            dispatch_ex.reg2 = id_dispatch.imm;
        end
        else begin
            dispatch_ex.reg2 = 32'b0;
        end
    end



endmodule