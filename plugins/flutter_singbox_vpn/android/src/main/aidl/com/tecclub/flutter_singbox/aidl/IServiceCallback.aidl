package com.tecclub.flutter_singbox.aidl;

interface IServiceCallback {
    void onServiceStatusChanged(int status);
    void onServiceAlert(int type, String message);
    void onTrafficUpdate(long uploadBytes, long downloadBytes);
}