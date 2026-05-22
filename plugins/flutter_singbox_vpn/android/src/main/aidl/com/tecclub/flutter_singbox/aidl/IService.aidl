package com.tecclub.flutter_singbox.aidl;

import com.tecclub.flutter_singbox.aidl.IServiceCallback;

interface IService {
    int getStatus();
    void registerCallback(in IServiceCallback callback);
    oneway void unregisterCallback(in IServiceCallback callback);
    
    // Get traffic statistics
    long getUploadBytes();
    long getDownloadBytes();
}