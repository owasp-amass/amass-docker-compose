#!/usr/bin/env python3
"""Check provider readiness, classifier state and MCP handshake without enumeration."""
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

FILES=["compose.yaml","compose.ai.yaml","compose.ai-stack.yaml","compose.ai-isolation.yaml"]
COMPOSE=["docker","compose"]
for item in FILES:
    COMPOSE+=["-f",item]

def run(*args):
    r=subprocess.run(args,capture_output=True,text=True)
    if r.returncode:
        sys.exit(f"ERROR: command failed: {' '.join(args)}\n{r.stderr}")
    return r.stdout

def request(url,method,payload,token,session=""):
    data=json.dumps(payload).encode() if payload is not None else None
    req=urllib.request.Request(url,data=data,method=method,headers={
        "Authorization":"Bearer "+token,
        "Accept":"application/json, text/event-stream",
        "Content-Type":"application/json",
        **({"Mcp-Session-Id":session} if session else {}),
    })
    with urllib.request.urlopen(req,timeout=20) as response:
        body=response.read()
        return response.status,response.headers,(json.loads(body) if body else {})

def main():
    cfg=json.loads(run(*COMPOSE,"--profile","ai","config","--format","json"))
    pub=cfg["services"]["ai-mcp"]["ports"][0]["published"]
    token=os.environ.get("AMASS_AI_MCP_TOKEN")
    if not token:
        path=Path("data/ai/.mcp-token")
        if not path.is_file():
            sys.exit("ERROR: MCP token not found; run scripts/ai-up.sh")
        token=path.read_text().strip()
    if len(token)<32:sys.exit("ERROR: invalid MCP token")

    status=json.loads(run(*COMPOSE,"exec","-T","provider-health",
                          "wget","-qO-","http://127.0.0.1:8091/readyz"))
    if status.get("status")!="ready":sys.exit("ERROR: inference provider is not ready")
    print(f"PASS: inference provider responded: {status.get('provider')} / {status.get('model')}")

    classifier=json.loads(run(*COMPOSE,"exec","-T","classifier",
                             "wget","-qO-","http://127.0.0.1:8092/readyz"))
    if classifier.get("status")!="ready":sys.exit("ERROR: classifier not ready")
    if classifier.get("trained"):
        print("PASS: classifier loaded:",classifier.get("model_id"))
    else:
        print("PASS: classifier running in explicit untrained escalation mode")
        print("      Supply human-labeled JSONL under data/classifier-training/labeled.jsonl to train it.")

    mcp=f"http://127.0.0.1:{pub}/mcp"
    code,headers,payload=request(mcp,"POST",{
        "jsonrpc":"2.0","id":1,"method":"initialize",
        "params":{"protocolVersion":"2025-11-25",
                  "capabilities":{},"clientInfo":{"name":"amass-ai-doctor","version":"1"}}
    },token)
    session=headers.get("Mcp-Session-Id","")
    if code!=200 or not session or "result" not in payload:sys.exit("ERROR: MCP initialize failed")
    code,_,_=request(mcp,"POST",{"jsonrpc":"2.0","method":"notifications/initialized"},token,session)
    if code!=202:sys.exit("ERROR: MCP initialization notification failed")
    code,_,payload=request(mcp,"POST",{"jsonrpc":"2.0","id":2,"method":"tools/list"},token,session)
    tools=payload.get("result",{}).get("tools",[])
    if code!=200 or not tools:sys.exit("ERROR: MCP tools/list failed")
    request(mcp,"DELETE",None,token,session)
    print(f"PASS: authenticated MCP HTTP initialized, listed {len(tools)} tools, terminated session")
    print("PASS: AI stack is ready. No domains were enumerated and no OAM relations were inserted.")

if __name__=="__main__":
    try:main()
    except Exception as error:sys.exit(f"ERROR: {error}")
