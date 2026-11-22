#!/usr/bin/env python3
"""
verify_consistency.py — Звірка кількості записів, контрольних сум SHA-256
та журналу підтверджених записів між лідером і фоловерами (або двома лідерами).
"""

import argparse
import hashlib
import json
import os
import sys
import time
from datetime import datetime
import psycopg

def parse_args():
    parser = argparse.ArgumentParser(description="Verify consistency across PostgreSQL nodes.")
    parser.add_argument("--nodes", nargs="+", required=True,
                        help="List of nodes in format host:port:dbname:user:password:label. Example: 127.0.0.1:5432:notes_a:repl_admin:repl_password_a:leader")
    parser.add_argument("--journal", default=None,
                        help="Path to writes_journal.ndjson to verify that all acknowledged writes exist on nodes.")
    parser.add_argument("--sample-check", action="store_true",
                        help="Perform sample comparison of first/last 100 rows.")
    return parser.parse_args()

def parse_node_str(node_str: str) -> dict:
    parts = node_str.split(":")
    if len(parts) < 6:
        raise ValueError(f"Invalid node format: {node_str}. Expected host:port:dbname:user:password:label")
    return {
        "host": parts[0],
        "port": int(parts[1]),
        "dbname": parts[2],
        "user": parts[3],
        "password": parts[4],
        "label": parts[5]
    }

def get_node_state(node: dict):
    conn_str = f"host={node['host']} port={node['port']} dbname={node['dbname']} user={node['user']} password={node['password']}"
    with psycopg.connect(conn_str) as conn:
        with conn.cursor() as cur:
            # Check if standby
            cur.execute("SELECT pg_is_in_recovery();")
            is_standby = cur.fetchone()[0]
            
            # Row count, min id, max id
            cur.execute("SELECT count(*), COALESCE(min(id), 0), COALESCE(max(id), 0) FROM notes;")
            count, min_id, max_id = cur.fetchone()
            
            # Checksum calculation: stream ordered rows and hash in Python with SHA-256
            # Hash format: id:author_id:title:body:updated_at
            hasher = hashlib.sha256()
            cur.execute("SELECT id, author_id, title, body, to_char(updated_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.USOF') FROM notes ORDER BY id;")
            
            while True:
                rows = cur.fetchmany(10000)
                if not rows:
                    break
                for row in rows:
                    line = f"{row[0]}|{row[1]}|{row[2]}|{row[3]}|{row[4]}\n"
                    hasher.update(line.encode("utf-8"))
            
            sha256_hex = hasher.hexdigest()
            
            # Last LSN info
            lsn_info = None
            if is_standby:
                cur.execute("SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();")
                receive_lsn, replay_lsn = cur.fetchone()
                lsn_info = f"receive={receive_lsn}, replay={replay_lsn}"
            else:
                cur.execute("SELECT pg_current_wal_lsn();")
                curr_lsn = cur.fetchone()[0]
                lsn_info = f"current={curr_lsn}"
                
            return {
                "label": node["label"],
                "host_port": f"{node['host']}:{node['port']}",
                "is_standby": is_standby,
                "count": count,
                "min_id": min_id,
                "max_id": max_id,
                "sha256": sha256_hex,
                "lsn_info": lsn_info
            }

def verify_journal(journal_path: str, primary_node: dict):
    if not os.path.exists(journal_path):
        print(f"Warning: Journal file {journal_path} not found. Skipping journal verification.")
        return
    
    print(f"\n--- Verifying Client Journal: {journal_path} ---")
    ack_ids = set()
    total_entries = 0
    with open(journal_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            entry = json.loads(line)
            if "id" in entry and entry["id"]:
                ack_ids.add(int(entry["id"]))
            total_entries += 1
            
    print(f"Found {total_entries} journal records ({len(ack_ids)} unique IDs).")
    
    conn_str = f"host={primary_node['host']} port={primary_node['port']} dbname={primary_node['dbname']} user={primary_node['user']} password={primary_node['password']}"
    with psycopg.connect(conn_str) as conn:
        with conn.cursor() as cur:
            # Check how many of ack_ids exist in notes
            cur.execute("SELECT id FROM notes;")
            db_ids = {row[0] for row in cur.fetchall()}
            
    missing_in_db = ack_ids - db_ids
    print(f"Acknowledged records present in DB: {len(ack_ids - missing_in_db)} / {len(ack_ids)}")
    if missing_in_db:
        print(f"CRITICAL: {len(missing_in_db)} acknowledged writes are MISSING in node {primary_node['label']}!")
        print(f"Sample missing IDs: {list(missing_in_db)[:10]}")
    else:
        print("PASS: 100% of acknowledged client writes exist in the database.")

def main():
    args = parse_args()
    nodes = [parse_node_str(n) for n in args.nodes]
    
    print(f"===========================================================")
    print(f"Consistency Verification [{datetime.now().isoformat()}]")
    print(f"Checking {len(nodes)} nodes: {', '.join(n['label'] for n in nodes)}")
    print(f"===========================================================")
    
    results = []
    for node in nodes:
        try:
            state = get_node_state(node)
            results.append(state)
        except Exception as e:
            print(f"ERROR querying node {node['label']} ({node['host']}:{node['port']}): {e}", file=sys.stderr)
            sys.exit(1)
            
    print(f"\n{'Node':<15} | {'Role':<10} | {'Count':<10} | {'ID Range':<18} | {'SHA-256 (first 16)':<20} | {'LSN'}")
    print("-" * 95)
    for r in results:
        role = "Standby" if r["is_standby"] else "Primary"
        id_range = f"{r['min_id']}..{r['max_id']}"
        print(f"{r['label']:<15} | {role:<10} | {r['count']:<10} | {id_range:<18} | {r['sha256'][:16]}... | {r['lsn_info']}")
        
    print("-" * 95)
    
    # Check if all counts and SHA-256 match
    counts = [r["count"] for r in results]
    hashes = [r["sha256"] for r in results]
    
    all_counts_match = len(set(counts)) == 1
    all_hashes_match = len(set(hashes)) == 1
    
    if all_counts_match and all_hashes_match:
        print(f"STATUS: ALL NODES ARE CONSISTENT! Row counts ({counts[0]}) and SHA-256 match exactly.")
    else:
        print(f"STATUS: DESYNCHRONIZATION DETECTED!")
        if not all_counts_match:
            print(f"  -> Row count mismatch: {counts}")
        if not all_hashes_match:
            print(f"  -> SHA-256 checksum mismatch!")
            
    if args.journal:
        verify_journal(args.journal, nodes[0])
        
    if not (all_counts_match and all_hashes_match):
        sys.exit(2)

if __name__ == "__main__":
    main()

