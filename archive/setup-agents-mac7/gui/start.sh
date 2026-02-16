#!/bin/bash
# Agent Control Center - Unified Launcher
# Runs both the terminal agents AND the Electron GUI

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shell config for npm access
source ~/.zshrc 2>/dev/null || source ~/.bashrc 2>/dev/null || true

echo "🚀 Starting Agent Control Center..."
echo ""

# Check if GUI dependencies are installed
if [ ! -d "$SCRIPT_DIR/node_modules" ]; then
    echo "📦 Installing GUI dependencies..."
    cd "$SCRIPT_DIR"
    npm install
    cd "$PROJECT_ROOT"
fi

# Start the Electron GUI in background
echo "🖥️  Launching Control Center GUI..."
cd "$SCRIPT_DIR"
npm start &
GUI_PID=$!
cd "$PROJECT_ROOT"

echo "   GUI started (PID: $GUI_PID)"
echo ""

# Give GUI time to start
sleep 2

echo "✅ Agent Control Center is running!"
echo ""
echo "📍 In the GUI:"
echo "   1. Click 'Select Project' and choose this project directory"
echo "   2. The GUI will connect and show real-time updates"
echo ""
echo "⌨️  Quick Commands (type in GUI command bar):"
echo "   • Natural language request → Sent to Master-1"
echo "   • 'fix worker-1: description' → Send urgent fix"
echo ""
echo "Press Ctrl+C to stop the GUI"
echo ""

# Wait for GUI to exit
wait $GUI_PID 2>/dev/null || true
