package Aclint;

import Vector::*;
import ConfigReg::*;
import RegIf::*;
import AclintRegs::*;

// 本包不认识任何总线：对外只给中立的 RegIf，接哪种总线由 wrap 或装配决定。
typedef struct {
  Bool ssip;
} AclintCfg;

// mtime 的时基不是核心时钟：RISC-V 要求它是一个固定频率的常在计数器，
// 所以拍子从外面来，休眠时也照走。
interface AclintPins;
  (* always_ready, always_enabled, prefix = "" *)
  method Action tick((* port = "rtc_tick" *) Bit#(1) v);
endinterface

interface AclintIfc#(numeric type aw, numeric type dw, numeric type harts);
  interface RegIf#(aw, dw) regs;
  interface AclintPins     pins;
  (* always_ready *) method Bit#(harts) msip;
  (* always_ready *) method Bit#(harts) mtip;
  // SETSSIP 是边沿不是电平：写 1 的那一拍拉高一拍，清零归软件（mip.SSIP 可写）
  (* always_ready *) method Bit#(harts) setssip;
endinterface

module mkAclint#(AclintCfg cfg)(AclintIfc#(aw, dw, harts))
    // 最后一条是数组写脉冲带来的：SETSSIP 要报「这一拍写的是哪一个」，
    // 下标得放得进契约的 16 位地址里
    provisos (Mul#(TDiv#(dw, 8), 8, dw), Add#(_a, 16, aw), Add#(_b, 1, dw),
              Add#(_c, 32, dw), Add#(_d, TLog#(TAdd#(harts, 1)), 16));

  AclintRegsIfc#(aw, dw, harts) r <- mkAclintRegs(
      AclintRegsCfg { ssip: cfg.ssip });

  Wire#(Bit#(1)) tickIn <- mkBypassWire;
  Reg#(Bit#(1))  prev   <- mkReg(0);

  rule count;
    prev <= tickIn;
    // 上升沿加一。时基慢于核心时钟，所以要取边沿而不是电平。
    if (tickIn == 1 && prev == 0) r.mtime_in(r.mtime + 1);
  endrule

  function Bit#(harts) fromVec(Vector#(harts, Bit#(1)) v) = pack(v);

  // 边沿打一拍再出去。组合直通会让「总线写 -> 边沿 -> 核 -> 总线」在装配里
  // 首尾相接（soc-linux 报 G0021），与 plic 的通知线是同一堵墙。
  // 规范明说「写 SETSSIP 保证反映到 SSIP，但不必立刻」，所以晚一拍合规。
  Reg#(Bit#(harts)) sset <- mkReg(0);

  rule edge_;
    Bit#(harts) o = 0;
    // 写 1 才送边沿，写 0 无效——这两条都是规范原文
    if (cfg.ssip && r.setssip_wr && r.setssip_wr_val == 1)
      o[r.setssip_wr_i] = 1;
    sset <= o;
  endrule

  interface regs = r.regs;
  interface AclintPins pins;
    method Action tick(Bit#(1) v); tickIn._write(v); endmethod
  endinterface
  method Bit#(harts) msip = fromVec(r.msip);
  method Bit#(harts) mtip;
    Bit#(harts) o = 0;
    // 规范只有一句：MTIME >= MTIMECMP 就挂起，小于就清掉。照抄，不加条件——
    // 「等于 0 当作永不」会让软件写 0 求立刻中断的用法失效。复位不误触发
    // 是靠 MTIMECMP 复位成全 1（规范说复位值未定，随实现挑）。
    for (Integer i = 0; i < valueOf(harts); i = i + 1)
      if (r.mtime >= r.mtimecmp[i]) o[i] = 1;
    return o;
  endmethod
  method Bit#(harts) setssip = sset;
endmodule

endpackage
