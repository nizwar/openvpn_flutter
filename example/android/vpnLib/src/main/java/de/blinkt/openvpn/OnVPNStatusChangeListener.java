package de.blinkt.openvpn;

public interface OnVPNStatusChangeListener {
      void onVPNStatusChanged(String status);

      void onConnectionStatusChanged(String duration, String lastPacketReceive, String byteIn, String byteOut);
}