#!/bin/bash
cd /home/owner/Desktop/my-app
jq '."worker-1".status = "assigned" | ."worker-1".current_task = "Add health-check endpoint to server"' .claude-shared-state/worker-status.json > /tmp/ws.json && mv /tmp/ws.json .claude-shared-state/worker-status.json
echo "worker-1 status updated"
cat .claude-shared-state/worker-status.json
