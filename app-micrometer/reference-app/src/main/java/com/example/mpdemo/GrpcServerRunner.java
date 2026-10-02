package com.example.mpdemo;

import io.grpc.Server;
import io.grpc.ServerBuilder;
import io.grpc.ServerInterceptors;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.IOException;

// Avvia un server gRPC puro (senza starter Spring) sulla porta 9555, con l'interceptor
// di durata applicato al servizio. Invocazione (come nel README di ../app) usando il
// .proto:
//   grpcurl -plaintext -proto rpc_ping.proto localhost:9555 micrometerdemo.AdService/GetAds
@Component
public class GrpcServerRunner {

    private static final Logger log = LoggerFactory.getLogger(GrpcServerRunner.class);

    private final int port;
    private final AdServiceImpl adService;
    private final RpcDurationInterceptor interceptor;
    private Server server;

    public GrpcServerRunner(@Value("${grpc.server.port:9555}") int port,
                            AdServiceImpl adService,
                            RpcDurationInterceptor interceptor) {
        this.port = port;
        this.adService = adService;
        this.interceptor = interceptor;
    }

    @PostConstruct
    public void start() throws IOException {
        server = ServerBuilder.forPort(port)
                .addService(ServerInterceptors.intercept(adService, interceptor))
                .build()
                .start();
        log.info("gRPC server in ascolto sulla porta {}", port);
    }

    @PreDestroy
    public void stop() {
        if (server != null) {
            server.shutdown();
        }
    }
}
