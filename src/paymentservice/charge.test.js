// Tests for the decline path: every card refusal must leave paymentservice
// as gRPC FAILED_PRECONDITION with a machine-readable reason, not as a
// server error. Run with: npm test (node --test).
const test = require('node:test');
const assert = require('node:assert');
const grpc = require('@grpc/grpc-js');

const charge = require('./charge');
const { CreditCardError } = charge;
const HipsterShopServer = require('./server');

const nextYear = new Date().getFullYear() + 1;
const request = (number, year = nextYear) => ({
  amount: { currency_code: 'USD', units: 10, nanos: 0 },
  credit_card: {
    credit_card_number: number,
    credit_card_cvv: 672,
    credit_card_expiration_year: year,
    credit_card_expiration_month: 1
  }
});

function declined (number, year, reason) {
  assert.throws(() => charge(request(number, year)), (err) => {
    assert.ok(err instanceof CreditCardError, 'a CreditCardError');
    assert.strictEqual(err.code, grpc.status.FAILED_PRECONDITION);
    assert.strictEqual(err.reason, reason);
    return true;
  });
}

test('valid VISA card is charged', () => {
  const res = charge(request('4432801561520454'));
  assert.match(res.transaction_id, /^[0-9a-f-]{36}$/);
});

test('invalid number is declined as invalid_number', () => {
  declined('1234', nextYear, 'invalid_number');
});

test('Visa Electron is declined as unsupported_card_brand', () => {
  declined('4917300800000000', nextYear, 'unsupported_card_brand');
});

test('expired card is declined as expired_card', () => {
  declined('4432801561520454', 2000, 'expired_card');
});

test('handler sends FAILED_PRECONDITION with decline-reason metadata', () => {
  let sent;
  HipsterShopServer.ChargeServiceHandler(
    { request: request('4917300800000000') },
    (err) => { sent = err; }
  );
  assert.strictEqual(sent.code, grpc.status.FAILED_PRECONDITION);
  assert.match(sent.details, /^Sorry, we cannot process visa_electron credit cards\./);
  assert.deepStrictEqual(sent.metadata.get('decline-reason'), ['unsupported_card_brand']);
});
