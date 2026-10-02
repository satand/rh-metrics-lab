package com.example.mpdemo;

import com.example.mpdemo.grpc.AdServiceGrpc;
import com.example.mpdemo.grpc.GetAdsRequest;
import com.example.mpdemo.grpc.GetAdsResponse;
import io.grpc.stub.StreamObserver;
import org.springframework.stereotype.Component;

// Implementazione minima dell'AdService: NON genera traffico da sola.
// La metrica rpc.server.duration cresce SOLO quando qualcuno invoca GetAds.
@Component
public class AdServiceImpl extends AdServiceGrpc.AdServiceImplBase {

    @Override
    public void getAds(GetAdsRequest request, StreamObserver<GetAdsResponse> responseObserver) {
        int count = request.getCount() > 0 ? request.getCount() : 1;
        GetAdsResponse.Builder builder = GetAdsResponse.newBuilder();
        for (int i = 0; i < count; i++) {
            builder.addAds("ad-" + i);
        }
        responseObserver.onNext(builder.build());
        responseObserver.onCompleted();
    }
}
