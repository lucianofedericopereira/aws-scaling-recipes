#!/bin/bash
#
# Main entry point — AWS Scaling Cookbook
# Prepares the environment and displays usage for the two scaling scenarios.
#
# Usage: ./main.sh [vertical|horizontal|both]

set -euo pipefail

echo "=== AWS Scaling Cookbook — Luciano Federico Pereira ==="
echo ""
echo "  Vertical Scaling:    Artes Graficas Buschi (2020)"
echo "  Horizontal Scaling:  Noblex / NEWSAN (2022)"
echo ""

# Make launch scripts executable
chmod +x Vertical/launch_vertical.sh
chmod +x Horizontal/launch_horizontal.sh

SCENARIO="${1:-}"

case "$SCENARIO" in
  vertical)
    echo "Launching vertical scaling stacks..."
    ./Vertical/launch_vertical.sh
    ;;
  horizontal)
    echo "Launching horizontal scaling stacks..."
    ./Horizontal/launch_horizontal.sh
    ;;
  both)
    echo "Launching both scenarios..."
    ./Vertical/launch_vertical.sh
    ./Horizontal/launch_horizontal.sh
    ;;
  *)
    echo "Usage: $0 [vertical|horizontal|both]"
    echo ""
    echo "  vertical     Deploy the vertical scaling stack (6 CF stacks)"
    echo "  horizontal   Deploy the horizontal scaling stack (7 CF stacks)"
    echo "  both         Deploy both stacks sequentially"
    echo ""
    echo "Before deploying, edit the configuration variables at the top of"
    echo "Vertical/launch_vertical.sh and Horizontal/launch_horizontal.sh with your AWS resource IDs."
    ;;
esac
