package main

// Tests for the checkout error path. checkoutservice is replaced by an
// in-process gRPC server (bufconn) that answers the way the real one does
// (see src/checkoutservice/charge_test.go); the handler, the templates and
// the metrics middleware are the real ones. The end-to-end check runs on the
// cluster.

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/sirupsen/logrus"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/frontend/genproto"
)

const shopperMsg = "Sorry, we cannot process visa_electron credit cards. Only VISA or MasterCard is accepted."

type checkoutStub struct {
	pb.UnimplementedCheckoutServiceServer
	err error
}

func (c *checkoutStub) PlaceOrder(context.Context, *pb.PlaceOrderRequest) (*pb.PlaceOrderResponse, error) {
	return nil, c.err
}

func declineErr(t *testing.T, domain string) error {
	t.Helper()
	st, err := status.New(codes.FailedPrecondition, shopperMsg).WithDetails(&errdetails.ErrorInfo{
		Reason: "unsupported_card_brand", Domain: domain,
	})
	if err != nil {
		t.Fatal(err)
	}
	return st.Err()
}

// checkout posts a valid checkout form through the metrics middleware to
// placeOrderHandler, with checkoutservice answering err.
func checkout(t *testing.T, err error) (*httptest.ResponseRecorder, *httpMetrics) {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	pb.RegisterCheckoutServiceServer(srv, &checkoutStub{err: err})
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	conn, cerr := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if cerr != nil {
		t.Fatal(cerr)
	}
	t.Cleanup(func() { _ = conn.Close() })
	fe := &frontendServer{checkoutSvcConn: conn}

	form := url.Values{
		"email": {"someone@example.com"}, "street_address": {"1600 Amphitheatre Parkway"},
		"zip_code": {"94043"}, "city": {"Mountain View"}, "state": {"CA"}, "country": {"United States"},
		"credit_card_number": {"4917300800000000"}, "credit_card_expiration_month": {"1"},
		"credit_card_expiration_year": {"2039"}, "credit_card_cvv": {"672"},
	}
	req := httptest.NewRequest(http.MethodPost, "/cart/checkout", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	logger := logrus.New()
	logger.Out = io.Discard
	ctx := context.WithValue(req.Context(), ctxKeyLog{}, logrus.FieldLogger(logger))
	ctx = context.WithValue(ctx, ctxKeySessionID{}, "test-session")

	m := newHTTPMetrics()
	rec := httptest.NewRecorder()
	m.middleware("", http.HandlerFunc(fe.placeOrderHandler)).ServeHTTP(rec, req.WithContext(ctx))
	return rec, m
}

func TestCheckoutDeclinedIs402WithShopperMessage(t *testing.T) {
	rec, m := checkout(t, declineErr(t, "paymentservice"))
	if rec.Code != http.StatusPaymentRequired {
		t.Fatalf("status = %d, want 402", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Payment declined") || !strings.Contains(body, "Only VISA or MasterCard is accepted.") {
		t.Errorf("page does not show the decline message for the shopper")
	}
	for _, internal := range []string{"rpc error", "checkoutservice", "failed to complete the order"} {
		if strings.Contains(body, internal) {
			t.Errorf("page leaks internal detail %q", internal)
		}
	}
	if n := m.requests[requestKey{http.MethodPost, "/cart/checkout", "402"}]; n != 1 {
		t.Errorf("metric POST /cart/checkout 402 = %d, want 1", n)
	}
}

func TestCheckoutFailuresStay500(t *testing.T) {
	cases := map[string]error{
		"internal":                          status.Error(codes.Internal, "failed to charge card"),
		"failed precondition, no details":   status.Error(codes.FailedPrecondition, shopperMsg),
		"failed precondition, other domain": declineErr(t, "shippingservice"),
	}
	for name, err := range cases {
		t.Run(name, func(t *testing.T) {
			rec, m := checkout(t, err)
			if rec.Code != http.StatusInternalServerError {
				t.Fatalf("status = %d, want 500", rec.Code)
			}
			if n := m.requests[requestKey{http.MethodPost, "/cart/checkout", "500"}]; n != 1 {
				t.Errorf("metric POST /cart/checkout 500 = %d, want 1", n)
			}
		})
	}
}
