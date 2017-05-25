#!/bin/bash

screen -d -m -S monitor
screen -r monitor -X screen
screen -r monitor -X exec ssh -t controller /bin/bash
screen -r monitor -X title controller
