#!/bin/bash
# planning-with-files-web: Show current planning status at a glance

WORK_DIR="/home/claude"

echo "📊 Planning Status"
echo "=================="

# Check if planning files exist
if [ ! -f "$WORK_DIR/task_plan.md" ]; then
    echo "❌ No planning session found. Run init-session.sh first."
    exit 1
fi

# Extract goal
echo ""
echo "🎯 Goal:"
grep -A1 "^## Goal" "$WORK_DIR/task_plan.md" | tail -1 | sed 's/^/   /'

# Extract current phase
echo ""
echo "📍 Current Phase:"
grep -A1 "^## Current Phase" "$WORK_DIR/task_plan.md" | tail -1 | sed 's/^/   /'

# Show phase statuses
echo ""
echo "📋 Phase Progress:"
grep -E "^\- \*\*Status:\*\*" "$WORK_DIR/task_plan.md" | while IFS= read -r line; do
    status=$(echo "$line" | grep -oP '(?<=\*\*Status:\*\* ).*')
    case "$status" in
        complete)   icon="✅" ;;
        in_progress) icon="🔄" ;;
        pending)    icon="⏳" ;;
        *)          icon="❓" ;;
    esac
    echo "   $icon $status"
done

# Count completed vs total checkboxes
total=$(grep -cE "\- \[.\]" "$WORK_DIR/task_plan.md" 2>/dev/null || echo 0)
done_count=$(grep -cE "\- \[x\]" "$WORK_DIR/task_plan.md" 2>/dev/null || echo 0)
echo ""
echo "📈 Checkboxes: $done_count/$total completed"

# Count errors
error_count=$(grep -c "^|" "$WORK_DIR/task_plan.md" 2>/dev/null || echo 0)
error_count=$((error_count > 2 ? error_count - 2 : 0))  # Subtract header rows
echo "⚠️  Errors logged: $error_count"

# Count findings
finding_lines=$(grep -c "^-" "$WORK_DIR/findings.md" 2>/dev/null || echo 0)
echo "📝 Findings entries: $finding_lines"

echo ""
echo "💡 Tip: Re-read task_plan.md before your next major decision"
