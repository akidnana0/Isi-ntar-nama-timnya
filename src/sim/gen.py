import hashlib, random, sys
random.seed(int(sys.argv[2]) if len(sys.argv)>2 else 1)
MEM=0x20000; mem=bytearray(MEM)
mode=sys.argv[1] if len(sys.argv)>1 else "edge"
if mode=="edge":
    lens=[0,1,7,8,55,111,112,113,119,120,127,128,129,239,240,255,256,1000,4500,2049]
elif mode=="big":      # throughput test: 12 docs x 4 KB
    lens=[4096]*12
elif mode=="one":
    lens=[100]
elif mode=="small":    # throughput test: 48 docs x 64 B (1 block each)
    lens=[64]*48
JOB_BASE=0x100; RES_BASE=0x1C000; addr=0x1008   # deliberately not 4KB aligned
exp=[]
for i,L in enumerate(lens):
    d=bytes(random.getrandbits(8) for _ in range(L))
    mem[addr:addr+L]=d
    jid=0x100+i
    w0=(jid<<48)|L; w1=addr
    mem[JOB_BASE+16*i:JOB_BASE+16*i+8]=w0.to_bytes(8,'little')
    mem[JOB_BASE+16*i+8:JOB_BASE+16*i+16]=w1.to_bytes(8,'little')
    exp.append((jid,hashlib.sha512(d).hexdigest(),L))
    addr=(addr+L+7)&~7
    addr+=8*random.randint(0,3)
assert addr<RES_BASE
open("mem.hex","w").write("\n".join("%02x"%b for b in mem))
open("expect.txt","w").write("\n".join("%x %s %d"%e for e in exp))
open("params.vh","w").write("`define NJOBS %d\n`define JOB_BASE 32'h%x\n`define RES_BASE 32'h%x\n"%(len(lens),JOB_BASE,RES_BASE))
