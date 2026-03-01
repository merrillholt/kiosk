#!/bin/bash
# Kill cage (which also kills chromium). The getty autologin mechanism
# will restart the session automatically.
pkill -x cage
