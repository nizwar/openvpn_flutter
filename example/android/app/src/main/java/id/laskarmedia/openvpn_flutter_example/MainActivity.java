package id.laskarmedia.openvpn_flutter_example;

import android.content.Intent;

import id.laskarmedia.openvpn_flutter.OpenVPNFlutterPlugin;
import io.flutter.embedding.android.FlutterActivity;

public class MainActivity extends FlutterActivity {
    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK);
        super.onActivityResult(requestCode, resultCode, data);
    }
}