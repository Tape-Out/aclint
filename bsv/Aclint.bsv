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
  (* always_ready *) method Bit#(harts) ssip;
endinterface

module mkAclint#(AclintCfg cfg)(AclintIfc#(aw, dw, harts))
    provisos (Mul#(TDiv#(dw, 8), 8, dw), Add#(_a, 16, aw), Add#(_b, 1, dw),
              Add#(_c, 32, dw));

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

  interface regs = r.regs;
  interface AclintPins pins;
    method Action tick(Bit#(1) v); tickIn._write(v); endmethod
  endinterface
  method Bit#(harts) msip = fromVec(r.msip);
  method Bit#(harts) mtip;
    Bit#(harts) o = 0;
    for (Integer i = 0; i < valueOf(harts); i = i + 1)
      if (r.mtime >= r.mtimecmp[i] && r.mtimecmp[i] != 0) o[i] = 1;
    return o;
  endmethod
  method Bit#(harts) ssip = cfg.ssip ? fromVec(r.ssip) : 0;
endmodule

endpackage
