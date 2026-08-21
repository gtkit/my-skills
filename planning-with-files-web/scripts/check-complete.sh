#!/bin/bash
# planning-with-files-web: Verify all phases complete before delivery

WORK_DIR="/home/claude"

echo "🔍 Completion Check"
echo "==================="

if [ ! -f "$WORK_DIR/task_plan.md" ]; then
    echo "❌ No task_plan.md found."
    exit 1
fi

# Check for incomplete phases
incomplete=$(grep -c "in_progress\|pending" "$WORK_DIR/task_plan.md" 2>/dev/null || echo 0)
complete=$(grep -c "complete" "$WORK_DIR/task_plan.md" 2>/dev/null || echo 0)

echo ""
echo "Phase Status:"
echo "  ✅ Complete: $complete"
echo "  ⏳ Remaining: $incomplete"

# Check for unchecked boxes
unchecked=$(grep -c "\- \[ \]" "$WORK_DIR/task_plan.md" 2>/dev/null || echo 0)
if [ "$unchecked" -gt 0 ]; then
    echo ""
    echo "⚠️  Unchecked items ($unchecked):"
    grep "\- \[ \]" "$WORK_DIR/task_plan.md" | sed 's/^/   /'
fi

# Check if deliverables exist in outputs
output_count=$(ls /mnt/user-data/outputs/ 2>/dev/null | wc -l)
echo ""
echo "📦 Files in outputs/: $output_count"

if [ "$incomplete" -eq 0 ] && [ "$unchecked" -eq 0 ]; then
    echo ""
    echo "✅ All phases complete! Ready for delivery."
    echo "   Don't forget to use present_files to share outputs with the user."
else
    echo ""
    echo "❌ Task not yet complete. Continue working through remaining phases."
fi
