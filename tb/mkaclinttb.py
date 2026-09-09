"""aclint 的行为测试台：时基走、比较到点、软件中断按位、数组不互相盖。

mtime 的拍子从外面来（RISC-V 要求它是固定频率的常在计数器），所以测试台自己
造一个方波，按上升沿数。

数组那一条是重点：`mtimecmp` 步长 8、元素宽 8，`msip` 步长 4。译码只查外层
范围的话，写第二项会写进第一项——同一个错在 plic、dma、eswitch 上都出现过。

认矩阵：`harts` 与 `ssip` 从这一点的旋钮来。ssip 关掉时期望整个反过来：
写得进去也该读回零，中断线始终不抬。
"""
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
out.mkdir(parents=True, exist_ok=True)
cfg = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
label = cfg.get("label", "")
k = cfg.get("knobs", {})
harts = int(k.get("harts", 1))
ssip = bool(k.get("ssip", False))

CMP = 6                      # mtimecmp[0] 的门限，走六个拍子就到
OTHER = 0x0000_7777          # 第二项写个显眼的，验数组不互相盖
second = harts >= 2

# 第二个 hart 的检查，只有 harts >= 2 才有意义
if second:
    arr_setup = "      2: wr(16'h4008, 32'h00007777);   // mtimecmp[1] 低字"
    arr_check = """  // 写第二项不该动到第一项：mtimecmp 步长 8、元素宽 8
  rule checkArr (ph == CheckArr);
    let x <- d.regs.access(RegReq { addr: 16'h4000, write: False,
                                    wdata: 0, wstrb: 4'hF });
    if (x.rdata != 32'h00000006) begin
      $display("FAIL mtimecmp[0] is %08h, want 00000006 (the array aliases)",
               x.rdata);
      bad <= True;
    end
    ph <= WaitTip;
  endrule
"""
    msip_second = """      4: wr(16'h0004, 1);            // msip[1]
      5: action
           // 一条规则里对 bad 只留一条写路径，两个 if 各写一次就是 G0004
           Bool wrong = False;
           if ((msipSeen[1] & 2) == 0) begin
             $display("FAIL msip[1] did not reach the pin: %02h", msipSeen[1]);
             wrong = True;
           end
           if ((msipSeen[1] & 1) != 0) begin
             $display("FAIL msip[0] came back on its own: %02h", msipSeen[1]);
             wrong = True;
           end
           if (wrong) bad <= True;
         endaction
"""
else:
    arr_setup = "      2: noAction;"
    arr_check = """  rule checkArr (ph == CheckArr);
    ph <= WaitTip;                       // 只有一个 hart，没有数组可对
  endrule
"""
    msip_second = "      4: noAction;\n      5: noAction;\n"

if ssip:
    # 规范三条：写 1 送边沿 · 最低位恒读 0 · 写 0 无效。逐条验。
    # 边沿在模块里打了一拍（见 Aclint.bsv 的 edge_），所以每次写完要空一拍再看。
    ssip_route = """     13: wr(16'hC004, 1);            // 送给 1 号 hart
     14: noAction;                   // 等那一拍
     15: action
           if (ssipSeen[0] != 2) begin
             $display("FAIL setssip[1] landed on %02h, want 02", ssipSeen[0]);
             bad <= True;
           end
         endaction
""" if second else ""
    ssip_check = """      6: wr(16'hC000, 1);            // 送一个边沿给 0 号 hart
      7: noAction;                   // 边沿打了一拍，等它
      8: action
           if ((ssipSeen[0] & 1) == 0) begin
             $display("FAIL setssip[0] was written but no edge came out: %02h",
                      ssipSeen[0]);
             bad <= True;
           end
           ssipSeen[0] <= 0;           // 清掉记录，后面几步验「不该有边沿」
         endaction
      9: action
           let x <- d.regs.access(RegReq { addr: 16'hC000, write: False,
                                           wdata: 0, wstrb: 4'hF });
           if (x.rdata != 0) begin
             $display("FAIL setssip reads %08h, the spec says it always reads 0",
                      x.rdata);
             bad <= True;
           end
         endaction
     10: wr(16'hC000, 0);             // 写 0 无效
     11: noAction;                   // 同样等一拍，写 0 若送了边沿这时才看得见
     12: action
           if (ssipSeen[0] != 0) begin
             $display("FAIL an edge appeared without a one being written: %02h",
                      ssipSeen[0]);
             bad <= True;
           end
         endaction
""" + ssip_route
    verdict = "time counts, compare fires, software interrupts are per hart, setssip is an edge"
else:
    ssip_check = """      6: wr(16'hC000, 1);            // ssip 关着，写了也不该有反应
      7: action
           if (ssipSeen[0] != 0) begin
             $display("FAIL ssip is off but the pin went high: %02h", ssipSeen[0]);
             bad <= True;
           end
         endaction
"""
    verdict = "time counts, compare fires, and the ssip gate really gates"

# 门限写 0：规范只说「MTIME >= MTIMECMP 就挂起」，没有「等于 0 当永不」这一条。
# 这一段能把那个多出来的条件抓出来——加了它，写 0 之后中断反而会掉。
cmp0_check = """     16: wr(16'h4000, 0);            // mtimecmp[0] 低字写 0
     17: wr(16'h4004, 0);            // 高字也写 0
     18: action
           if ((mtipSeen[1] & 1) == 0) begin
             $display("FAIL mtimecmp is 0 and mtime has run, yet mtip is low: %02h",
                      mtipSeen[1]);
             bad <= True;
           end
         endaction
"""

txt = f'''package Aclint{label}Tb;

import Vector::*;
import RegIf::*;
import Aclint::*;

// 由 tb/mkaclinttb.py 生成，勿手改。这一点：harts={harts} ssip={ssip}

typedef enum {{ Setup, CheckArr, WaitTip, Msip, Done }}
  Phase deriving (Bits, Eq);

(* synthesize *)
module mkAclint{label}Tb(Empty);
  AclintIfc#(16, 32, {harts}) d <- mkAclint(
      AclintCfg {{ ssip: {"True" if ssip else "False"} }});

  Reg#(Phase)    ph   <- mkReg(Setup);
  Reg#(Bit#(8))  s    <- mkReg(0);
  Reg#(Bit#(32)) cyc  <- mkReg(0);
  Reg#(Bool)     bad  <- mkReg(False);
  Reg#(Bit#(3))  tdiv <- mkReg(0);
  Reg#(Bit#(1))  tck  <- mkReg(0);
  // 引脚那条规则每拍都跑，凡是它写、检查规则读的量都得用 CReg
  Reg#(Bit#({harts})) mtipSeen[2] <- mkCReg(2, 0);
  Reg#(Bit#({harts})) msipSeen[2] <- mkCReg(2, 0);
  Reg#(Bit#({harts})) ssipSeen[2] <- mkCReg(2, 0);

  rule pins;
    // 时基慢于核心时钟：四拍翻一次，八拍一个上升沿
    // 一个寄存器在一条规则里只留一条写路径，否则 bsc 判成并行冲突（G0004）
    if (tdiv == 3) begin tdiv <= 0; tck <= ~tck; end
    else tdiv <= tdiv + 1;
    d.pins.tick(tck);
    mtipSeen[0] <= d.mtip;
    msipSeen[0] <= d.msip;
  endrule

  // 边沿是「写总线的那一拍」才有的，所以累积不能和采样电平放同一条规则：
  // 采样电平要排在检查之前（检查读的是这一拍采到的），
  // 累积边沿要排在检查之后（边沿正是检查那条规则写出来的）。
  // 端口也跟着分：检查用 0，累积用 1。
  rule sswi;
    ssipSeen[1] <= ssipSeen[1] | d.setssip;
  endrule

  rule tick_;
    cyc <= cyc + 1;
    if (cyc > 40000) begin
      $display("TIMEOUT in phase %0d", pack(ph));
      $finish(1);
    end
  endrule

  function Action wr(Bit#(16) a, Bit#(32) v) = action
    let _ <- d.regs.access(RegReq {{ addr: a, write: True,
                                     wdata: v, wstrb: 4'hF }});
  endaction;

  rule setup (ph == Setup);
    case (s)
      0: wr(16'h4000, {CMP});            // mtimecmp[0] 低字
      1: wr(16'h4004, 0);            // 高字
{arr_setup}
      default: ph <= CheckArr;
    endcase
    if (s < 3) s <= s + 1; else s <= 0;
  endrule

{arr_check}
  // 时基走到门限，mtip 该抬起来
  rule waitTip (ph == WaitTip);
    if ((mtipSeen[1] & 1) == 1) ph <= Msip;
  endrule

  rule msip_ (ph == Msip);
    case (s)
      0: wr(16'h0000, 1);            // msip[0]
      1: action
           if ((msipSeen[1] & 1) == 0) begin
             $display("FAIL msip[0] did not reach the pin: %02h", msipSeen[1]);
             bad <= True;
           end
         endaction
      2: wr(16'h0000, 0);
      3: action
           if ((msipSeen[1] & 1) != 0) begin
             $display("FAIL msip[0] stayed high after being cleared: %02h",
                      msipSeen[1]);
             bad <= True;
           end
         endaction
{msip_second}{ssip_check}{cmp0_check}      default: ph <= Done;
    endcase
    if (s < 25) s <= s + 1; else s <= 0;
  endrule

  rule fin (ph == Done);
    if (bad) $display("FAILED");
    else $display("PASS aclint: {verdict}");
    $finish(bad ? 1 : 0);
  endrule
endmodule

endpackage
'''

(out / f"Aclint{label}Tb.bsv").write_text(txt, encoding="utf-8")
print(f"  aclint 行为测试台就位：harts={harts} ssip={ssip}")
