#!/bin/bash
# planning-with-files-web: Initialize planning session
# Creates task_plan.md, findings.md, and progress.md in /home/claude/

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="/home/claude"
DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M)

echo "📋 Planning with Files (Web Edition) - Session Init"
echo "=================================================="

# Check if planning files already exist
if [ -f "$WORK_DIR/task_plan.md" ] || [ -f "$WORK_DIR/findings.md" ] || [ -f "$WORK_DIR/progress.md" ]; then
    echo ""
    echo "⚠️  Existing planning files detected:"
    [ -f "$WORK_DIR/task_plan.md" ] && echo "   - task_plan.md ($(wc -l < "$WORK_DIR/task_plan.md") lines)"
    [ -f "$WORK_DIR/findings.md" ] && echo "   - findings.md ($(wc -l < "$WORK_DIR/findings.md") lines)"
    [ -f "$WORK_DIR/progress.md" ] && echo "   - progress.md ($(wc -l < "$WORK_DIR/progress.md") lines)"
    echo ""
    echo "   Backing up to *.bak before overwriting..."
    [ -f "$WORK_DIR/task_plan.md" ] && cp "$WORK_DIR/task_plan.md" "$WORK_DIR/task_plan.md.bak"
    [ -f "$WORK_DIR/findings.md" ] && cp "$WORK_DIR/findings.md" "$WORK_DIR/findings.md.bak"
    [ -f "$WORK_DIR/progress.md" ] && cp "$WORK_DIR/progress.md" "$WORK_DIR/progress.md.bak"
fi

# Copy templates
cp "$SKILL_DIR/templates/task_plan.md" "$WORK_DIR/task_plan.md"
cp "$SKILL_DIR/templates/findings.md" "$WORK_DIR/findings.md"
cp "$SKILL_DIR/templates/progress.md" "$WORK_DIR/progress.md"

# Set the date in progress.md
sed -i "s/\[DATE\]/$DATE/" "$WORK_DIR/progress.md"
sed -i "s/\[timestamp\]/$DATE $TIME/" "$WORK_DIR/progress.md"

echo ""
echo "✅ Planning files created in $WORK_DIR/:"
echo "   📄 task_plan.md  — Phase tracking & decisions"
echo "   📄 findings.md   — Research & knowledge storage"
echo "   📄 progress.md   — Session log & test results"
echo ""
echo "🔄 Next steps:"
echo "   1. Edit task_plan.md with your goal and phases"
echo "   2. Start working through phases"
echo "   3. Update findings.md after every 2 searches"
echo "   4. Log errors and progress as you go"
echo ""
echo "💡 Re-read task_plan.md before major decisions!"
