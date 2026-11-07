#!/usr/bin/env python3
"""Controleert of de SDM630 via de USR-DR302 bereikbaar is.

Probeert Modbus TCP en RTU over TCP, leest een paar waarden en vertelt welke
MODBUS_MODE in .env hoort. Leest alleen; er gaat niets naar de meter toe.

Gebruik: docker compose run --rm check
of:      python check_meter.py <host> [poort] [modbus-adres]
"""
import os
import struct
import sys

from pymodbus.client import ModbusTcpClient
from pymodbus.exceptions import ModbusException
from pymodbus.framer import FramerType

REGISTERS = [
    ("Spanning L1", 0x0000, "V"),
    ("Spanning L2", 0x0002, "V"),
    ("Spanning L3", 0x0004, "V"),
    ("Stroom L1", 0x0006, "A"),
    ("Stroom L2", 0x0008, "A"),
    ("Stroom L3", 0x000A, "A"),
    ("Stroom N", 0x00E0, "A"),
    ("Vermogen totaal", 0x0034, "W"),
    ("Frequentie", 0x0046, "Hz"),
    ("Import totaal", 0x0048, "kWh"),
]
MODES = [("TCP", FramerType.SOCKET), ("RTUoverTCP", FramerType.RTU)]


def read_float(client, address, slave):
    reply = client.read_input_registers(address, count=2, device_id=slave)
    if reply.isError():
        raise ModbusException(str(reply))
    return struct.unpack(">f", struct.pack(">HH", *reply.registers))[0]


def try_mode(host, port, slave, framer):
    """Geeft de gelezen waarden, of None als deze modus niet werkt."""
    client = ModbusTcpClient(host, port=port, framer=framer, timeout=2, retries=1)
    try:
        if not client.connect():
            return None
        return [(label, read_float(client, address, slave), unit)
                for label, address, unit in REGISTERS]
    except (ModbusException, OSError, struct.error):
        return None
    finally:
        client.close()


def plausible(values):
    """Spanning op een fase moet rond de 230 V liggen; anders is het ruis."""
    return any(180 < value < 270 for _, value, unit in values if unit == "V")


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("MODBUS_HOST")
    port = int(sys.argv[2] if len(sys.argv) > 2 else os.environ.get("MODBUS_PORT", 502))
    slave = int(sys.argv[3] if len(sys.argv) > 3 else os.environ.get("MODBUS_SLAVE", 1))
    if not host:
        sys.exit("Geef een host op, of zet MODBUS_HOST.")

    print(f"Meter zoeken op {host}:{port}, Modbus-adres {slave}")
    for mode, framer in MODES:
        values = try_mode(host, port, slave, framer)
        if values is None:
            print(f"  {mode}: geen antwoord")
            continue
        if not plausible(values):
            print(f"  {mode}: antwoord, maar geen geldige spanning")
            continue
        print(f"  {mode}: werkt\n")
        for label, value, unit in values:
            print(f"  {label:<16} {value:>10.2f} {unit}")
        print(f"\nZet in .env: MODBUS_MODE={mode}")
        if slave != 1:
            print(f"Zet in telegraf/telegraf.conf: slave_id = {slave}")
        current_n = dict((label, value) for label, value, _ in values)["Stroom N"]
        if current_n == 0:
            print("Let op: Stroom N is precies 0. Staat de meter op 3P4W?")
        return

    sys.exit("\nGeen werkende verbinding. Controleer poort, Modbus-adres, baudrate, "
             "pariteit en A/B-bedrading.")


if __name__ == "__main__":
    main()
