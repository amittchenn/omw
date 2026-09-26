#!/bin/bash
# Always start the server with the hangout environment's Python (3.12)
cd "$(dirname "$0")"
/opt/anaconda3/envs/hangout/bin/python -m uvicorn server:app --reload