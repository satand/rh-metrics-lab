package com.example.mpdemo;

import io.grpc.ForwardingServerCall;
import io.grpc.Metadata;
import io.grpc.ServerCall;
import io.grpc.ServerCallHandler;
import io.grpc.ServerInterceptor;
import io.grpc.Status;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Component;

import java.util.concurrent.TimeUnit;

// Strumento analogo a quello che nell'adservice fa crescere rpc_server_duration:
// misura la durata di OGNI chiamata gRPC in ingresso (dal riceimento al close) e la
// registra come osservazione del Timer "rpc.server.duration". Nessun contatore sale
// se non arriva una chiamata.
//
//   rpc.server.duration  ->  su UWM: rpc_server_duration_milliseconds_{count,sum,bucket}
//   rpc.server.calls     ->  contatore chiamate ricevute
@Component
public class RpcDurationInterceptor implements ServerInterceptor {

    private final MeterRegistry registry;
    private final Counter calls;

    public RpcDurationInterceptor(MeterRegistry registry) {
        this.registry = registry;
        this.calls = Counter.builder("rpc.server.calls")
                .description("Simulated RPC calls received")
                .register(registry);
    }

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
            ServerCall<ReqT, RespT> call, Metadata headers, ServerCallHandler<ReqT, RespT> next) {

        String rpcService = call.getMethodDescriptor().getServiceName();
        String rpcMethod = call.getMethodDescriptor().getBareMethodName();
        long startNanos = System.nanoTime();
        calls.increment();

        ServerCall<ReqT, RespT> timedCall = new ForwardingServerCall.SimpleForwardingServerCall<>(call) {
            @Override
            public void close(Status status, Metadata trailers) {
                Timer.builder("rpc.server.duration")
                        .description("Simulated server-side RPC duration")
                        .publishPercentiles(0.5, 0.95, 0.99)
                        .tag("rpc_service", rpcService)
                        .tag("rpc_method", rpcMethod)
                        .tag("rpc_grpc_status_code", status.getCode().name())
                        .register(registry)
                        .record(System.nanoTime() - startNanos, TimeUnit.NANOSECONDS);
                super.close(status, trailers);
            }
        };
        return next.startCall(timedCall, headers);
    }
}
