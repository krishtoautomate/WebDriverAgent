#!/bin/bash

# build
# xcodebuild build-for-testing -scheme replaykit2UITests -sdk iphoneos -configuration Release -derivedDataPath .

# # Define the path to the IPA file
# ipa_file="Build/Products/Release-iphoneos/replaykit2.app"

# # Get the list of connected iOS devices
# device_list=$(idevice_id -l)

# # Loop through each device and install the IPA file
# for device_udid in $device_list; do
#   echo "Installing IPA file on device: $device_udid"
#   ideviceinstaller -u $device_udid -i $ipa_file
#   echo "Installation completed on device: $device_udid"
# done

ipa_file="/Users/home/Desktop/RDSRunner-Runner.app"

# Get the list of connected iOS devices
device_list=$(idevice_id -l)

# Loop through each device and install the IPA file
for device_udid in $device_list; do
  echo "Installing IPA file on device: $device_udid"
  ideviceinstaller -u $device_udid -i $ipa_file
  echo "Installation completed on device: $device_udid"
done