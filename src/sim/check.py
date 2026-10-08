import sys
off=int(sys.argv[1],16) if len(sys.argv)>1 else 0
exp={int(l.split()[0],16)-off:(l.split()[1],int(l.split()[2])) for l in open("expect.txt")}
got={}
for l in open("got.txt"):
    p=l.split(); got[int(p[0],16)]=p[1] if len(p)>1 else ""
ok=0
for jid,(d,L) in exp.items():
    g=got.get(jid)
    if g==d: ok+=1
    else: print("MISMATCH job %x len %d: got %s"%(jid,L,"(missing)" if g is None else g[:32]+"..."))
print("%d/%d correct"%(ok,len(exp)))
