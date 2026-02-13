#!/bin/bash
# Refresh cron job data for Mission Control
mkdir -p /home/fx/clawd/mission-control/data
openclaw cron list --json > /home/fx/clawd/mission-control/data/cron-jobs.json 2>/dev/null
