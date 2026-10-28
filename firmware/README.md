# Thingy:91 X firmware

`parcel_tracker.hex` is the SmartParcel firmware for the **nRF9151** on the Nordic Thingy:91 X.
It classifies parcel handling and reports the results to nRF Cloud over CoAP.

It's a **merged image**: bootloaders (NSIB + MCUboot), TF-M, the application and UICR in one
file, built with nRF Connect SDK v3.2.99 for `thingy91x/nrf9151/ns`. A merged image is
programmed over SWD with an **external debug probe**. It can't be sent over the Thingy's USB
port, because USB programming (MCUboot serial recovery) only accepts application update
images such as `dfu_application.zip`.

## What you need

- Nordic Thingy:91 X and a USB-C cable (for power)
- An external debug probe that supports Arm Cortex-M33, for example an **nRF9151 DK**
  (it has a debug-out port) or a SEGGER J-Link
- A 10-pin 2x5 socket-socket 1.27 mm SWD cable
- Either [nRF Util](https://www.nordicsemi.com/Products/Development-tools/nRF-Util/) with the
  `device` command (`nrfutil install device`), or
  [nRF Connect for Desktop](https://www.nordicsemi.com/Products/Development-tools/nRF-Connect-for-Desktop)
  with the **Programmer** app

## Prepare the hardware

1. Remove the Thingy:91 X's rubber cover.
2. Connect the SWD cable from the probe's debug-out connector to **P8** on the Thingy:91 X.
3. Connect the probe to your computer over USB, and power the Thingy:91 X over USB-C.
4. Switch the Thingy:91 X on: **SW1** to **ON**.
5. Set the SWD target switch **SW2** to **nRF91**. This selects the nRF9151, not the nRF5340.

## Option A: nRF Util (command line)

```sh
# 1. Find the probe's serial number (J-Link product, 9–10 digits, "jlink" trait)
nrfutil device list

# 2. Erase the nRF9151 and program the merged image, then reset
nrfutil device program \
  --firmware firmware/parcel_tracker.hex \
  --serial-number <JLINK_SERIAL> \
  --traits jlink --x-family nrf91 \
  --options chip_erase_mode=ERASE_ALL,verify=VERIFY_READ,reset=RESET_SYSTEM
```

`ERASE_ALL` is required. The image rewrites the bootloaders and UICR, and programming fails
if old UICR contents are left. The modem firmware is separate and is not affected by the
erase.

If programming fails because the device is protected (APPROTECT), recover it first, then run
the program command again:

```sh
nrfutil device recover --serial-number <JLINK_SERIAL> --x-family nrf91
```

## Option B: Programmer app (nRF Connect for Desktop)

1. Open nRF Connect for Desktop and launch **Programmer**.
2. Click **Select device** and choose the debug probe (for example the nRF9151 DK).
   **Device memory layout** shows the nRF9151 once it's connected. If the nRF5340 shows
   instead, check that **SW2** is set to **nRF91**.
3. In the **File** section, click **Add file → Browse** and select `firmware/parcel_tracker.hex`.
4. In the **Device** section, click **Erase & write**.
5. Wait until the progress animation in **Device memory layout** stops, then click
   **Clear files**.

## After flashing

1. Disconnect the probe, power-cycle the Thingy:91 X (**SW1** off and on) and put the cover
   back on.
2. Make sure the device belongs to **your** nRF Cloud team. Data only reaches your dashboard
   when the device is on the team that owns the MRS destination (see the main README). If it
   isn't onboarded yet, follow
   [nRF Cloud device onboarding](https://docs.nrfcloud.com/docs/nrfcloud/secure-device-onboarding).
3. Once it's connected to LTE and nRF Cloud, move the parcel. Classifications should appear
   on the dashboard within seconds. If they don't:
   - `scripts/mrs.sh status` shows delivery errors.
   - `raw_messages` in the PocketBase admin UI shows what arrived.

To watch the firmware's log, connect to the Thingy:91 X's USB serial port with the
**Serial Terminal** app in nRF Connect for Desktop.

## References

- [Updating the Thingy:91 X firmware using nRF Util](https://nrfconnectdocs.nordicsemi.com/ncs/latest/nrf/app_dev/device_guides/thingy91x/thingy91x_updating_fw_programmer.html)
- [Programmer app: programming Nordic Thingy devices](https://docs.nordicsemi.com/bundle/nrf-connect-for-desktop/page/app/pc-nrfconnect-programmer/programming_thingy.html)
- [`nrfutil device program` options](https://docs.nordicsemi.com/bundle/nrfutil/page/nrfutil-device/nrfutil-device-program.html)
