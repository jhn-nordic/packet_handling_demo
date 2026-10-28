# Thingy:91 X firmware

`parcel_tracker.hex` is the SmartParcel firmware for the **nRF9151** on the Nordic Thingy:91 X.
It classifies parcel handling and reports the results to nRF Cloud over CoAP. It's built on
the [Asset Tracker Template](https://docs.nordicsemi.com/bundle/asset-tracker-template-latest/page/index.html)
(ATT), so the ATT's onboarding, provisioning and shell commands apply.

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
2. If the Thingy:91 X isn't on your nRF Cloud account yet, claim it (next section). If it is
   already in **Fleet → Devices** in your organization, skip ahead.
3. Once it's connected to LTE and nRF Cloud, move the parcel. Classifications should appear
   on the dashboard within seconds. If they don't:
   - `scripts/mrs.sh status` shows delivery errors.
   - `raw_messages` in the PocketBase admin UI shows what arrived.

## Claim the device on your nRF Cloud account

A Thingy:91 X can only send data to nRF Cloud after it has been claimed (onboarded) to an
account. It must be claimed to the **same organization that owns your MRS destination**,
otherwise its messages never reach your dashboard. A device belongs to one organization at a
time. If it's
still on another account (for example a colleague's or a previous demo's), remove it there
first.

Until it's claimed, the device log shows `Provisioning failed, device not claimed`.

### 1. Get the attestation token from the device shell

1. Connect the Thingy:91 X to your computer with USB-C and switch it on.
2. Open the **Serial Terminal** app in nRF Connect for Desktop (or any terminal at 115200 baud)
   and connect to the Thingy:91 X's serial port. If several ports show up, use the one that
   gives you a `uart:~$` prompt when you press Enter.
3. Run:

   ```
   uart:~$ at at%attesttoken
   ```

4. The reply looks like `%ATTESTTOKEN: "<part 1>.<part 2>"`. Copy the value inside the
   quotes. Leave out the `%ATTESTTOKEN:` prefix and the quotes, and copy both parts,
   including the `.` in the middle.

### 2. Add the device in nRF Cloud

1. Log in to [nrfcloud.com](https://nrfcloud.com) and open the organization in `NRFCLOUD_ORG`
   (the one that owns your MRS destination).
2. Go to **Fleet → Devices** and select **Add devices**.
3. Choose **nRF91 Series** as the device type.
4. Paste the token into **Attestation token**, preview it, and confirm.

### 3. Provision the device

After claiming, the device fetches its nRF Cloud credentials from the provisioning service. It
does this on its own at the next scheduled check-in. To do it right away, run this in the
same shell:

```
uart:~$ att_cloud provision
```

Provisioning takes up to a minute. LTE disconnecting and reconnecting during it is normal,
because the modem goes offline while the credentials are written. When it's done, the device
shows up as connected under **Fleet → Devices**, and classifications start flowing to your
dashboard.

More detail: [ATT: Connecting to nRF Cloud](https://docs.nordicsemi.com/bundle/asset-tracker-template-latest/page/common/connecting.html) ·
[nRF Cloud device onboarding](https://docs.nrfcloud.com/docs/nrfcloud/device-onboarding)

To watch the firmware's log at any time, keep the same serial terminal open.

## References

- [Updating the Thingy:91 X firmware using nRF Util](https://nrfconnectdocs.nordicsemi.com/ncs/latest/nrf/app_dev/device_guides/thingy91x/thingy91x_updating_fw_programmer.html)
- [Programmer app: programming Nordic Thingy devices](https://docs.nordicsemi.com/bundle/nrf-connect-for-desktop/page/app/pc-nrfconnect-programmer/programming_thingy.html)
- [`nrfutil device program` options](https://docs.nordicsemi.com/bundle/nrfutil/page/nrfutil-device/nrfutil-device-program.html)
