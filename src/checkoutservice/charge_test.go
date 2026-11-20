package main

// Unit tests for the payment error path. paymentservice is replaced by an
// in-process gRPC server (bufconn) that answers the way the real one does
// (see src/paymentservice/charge.test.js); codes, trailers and details go
// through the real gRPC library. The end-to-end check runs on the cluster.

import (
	"context"
	"net"
	"testing"

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/checkoutservice/genproto"
)

const declineMsg = "Sorry, we cannot process visa_electron credit cards. Only VISA or MasterCard is accepted."

type paymentStub struct {
	pb.UnimplementedPaymentServiceServer
	code   codes.Code
	reason string
}

func (p *paymentStub) Charge(ctx context.Context, _ *pb.ChargeRequest) (*pb.ChargeResponse, error) {
	if p.reason != "" {
		_ = grpc.SetTrailer(ctx, metadata.Pairs("decline-reason", p.reason))
	}
	if p.code == codes.OK {
		return &pb.ChargeResponse{TransactionId: "tx-1"}, nil
	}
	return nil, status.Error(p.code, declineMsg)
}

func checkoutWithPayment(t *testing.T, p *paymentStub) *checkoutService {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	pb.RegisterPaymentServiceServer(srv, p)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return &checkoutService{paymentSvcConn: conn}
}

func charge(t *testing.T, p *paymentStub) (string, error) {
	t.Helper()
	return checkoutWithPayment(t, p).chargeCard(context.Background(),
		&pb.Money{CurrencyCode: "USD", Units: 10}, &pb.CreditCardInfo{CreditCardNumber: "4917300800000000"})
}

func TestChargeCardOK(t *testing.T) {
	tx, err := charge(t, &paymentStub{code: codes.OK})
	if err != nil || tx != "tx-1" {
		t.Fatalf("got (%q, %v), want (tx-1, nil)", tx, err)
	}
}

func TestDeclineBecomesFailedPreconditionWithErrorInfo(t *testing.T) {
	_, err := charge(t, &paymentStub{code: codes.FailedPrecondition, reason: "unsupported_card_brand"})
	d, ok := err.(*cardDeclinedError)
	if !ok {
		t.Fatalf("chargeCard error = %v (%T), want *cardDeclinedError", err, err)
	}
	if d.reason != "unsupported_card_brand" || d.message != declineMsg {
		t.Fatalf("got reason %q message %q", d.reason, d.message)
	}

	st := status.Convert(chargeErrorStatus(err))
	if st.Code() != codes.FailedPrecondition || st.Message() != declineMsg {
		t.Fatalf("PlaceOrder status = %v %q, want FailedPrecondition with the shopper message", st.Code(), st.Message())
	}
	var info *errdetails.ErrorInfo
	for _, det := range st.Details() {
		if ei, ok := det.(*errdetails.ErrorInfo); ok {
			info = ei
		}
	}
	if info == nil || info.GetReason() != "unsupported_card_brand" || info.GetDomain() != "paymentservice" {
		t.Fatalf("ErrorInfo = %v, want reason unsupported_card_brand, domain paymentservice", info)
	}
}

func TestFailuresStayInternal(t *testing.T) {
	cases := map[string]*paymentStub{
		"unavailable":                    {code: codes.Unavailable},
		"failed precondition, no reason": {code: codes.FailedPrecondition},
		"legacy code 400":                {code: codes.Code(400), reason: "unsupported_card_brand"},
	}
	for name, p := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := charge(t, p)
			if _, ok := err.(*cardDeclinedError); ok {
				t.Fatalf("%v must not be treated as a decline", err)
			}
			if c := status.Code(chargeErrorStatus(err)); c != codes.Internal {
				t.Fatalf("PlaceOrder code = %v, want Internal", c)
			}
		})
	}
}
