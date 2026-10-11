package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func openTest(t *testing.T, opts Options) (*Store, *clock) {
	t.Helper()
	c := &clock{t: time.Unix(1_800_000_000, 0)}
	if opts.Now == nil {
		opts.Now = c.now
	}
	s, err := Open(filepath.Join(t.TempDir(), "test.db"), opts)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, c
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

func newDevice(t *testing.T, s *Store) Device {
	t.Helper()
	d, created, err := s.RegisterDevice(context.Background(), randBytes(32), randBytes(32))
	if err != nil || !created {
		t.Fatalf("register: created=%v err=%v", created, err)
	}
	return d
}

func newInvite(t *testing.T, s *Store, circleID, deviceID string, ttl time.Duration, uses int) (Invite, []byte) {
	t.Helper()
	token := randBytes(32)
	h := sha256.Sum256(token)
	inv, err := s.CreateInvite(context.Background(), circleID, deviceID, h[:], []byte("sealed"), ttl, uses)
	if err != nil {
		t.Fatal(err)
	}
	return inv, token
}

func TestReopenKeepsDataAndSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.db")
	s, err := Open(path, Options{})
	if err != nil {
		t.Fatal(err)
	}
	d := newDevice(t, s)
	s.Close()

	s, err = Open(path, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	got, err := s.DeviceBySigningKey(context.Background(), d.SigningKey)
	if err != nil || got.ID != d.ID {
		t.Fatalf("after reopen: %v %v", got.ID, err)
	}
}

func TestRegisterDeviceIdempotentAndConflict(t *testing.T) {
	s, _ := openTest(t, Options{})
	ctx := context.Background()
	sk, ak := randBytes(32), randBytes(32)

	d1, created, err := s.RegisterDevice(ctx, sk, ak)
	if err != nil || !created {
		t.Fatal(created, err)
	}
	if d1.ID != DeviceID(sk) {
		t.Fatal("device id not derived from signing key")
	}
	d2, created, err := s.RegisterDevice(ctx, sk, ak)
	if err != nil || created || d2.ID != d1.ID {
		t.Fatalf("second register: created=%v err=%v", created, err)
	}
	if _, _, err := s.RegisterDevice(ctx, sk, randBytes(32)); !errors.Is(err, ErrConflict) {
		t.Fatalf("err = %v, want ErrConflict", err)
	}
	if _, _, err := s.RegisterDevice(ctx, randBytes(31), ak); !errors.Is(err, ErrInvalid) {
		t.Fatalf("err = %v, want ErrInvalid", err)
	}
}

func TestCircleLifecycle(t *testing.T) {
	s, _ := openTest(t, Options{})
	ctx := context.Background()
	alice, bob := newDevice(t, s), newDevice(t, s)

	cid, epoch, err := s.CreateCircle(ctx, alice.ID, []byte("meta"), []byte("alice-card"), []byte("alice-wrapped"))
	if err != nil || epoch != 1 {
		t.Fatal(epoch, err)
	}

	// Bob is not a member yet.
	if _, err := s.GetCircle(ctx, cid, bob.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-member get: %v", err)
	}

	inv, token := newInvite(t, s, cid, alice.ID, time.Hour, 1)
	res, err := s.RedeemInvite(ctx, inv.ID, bob.ID, token, []byte("bob-card"))
	if err != nil {
		t.Fatal(err)
	}
	if res.CircleID != cid || res.Epoch != 1 || string(res.SealedKey) != "sealed" || res.Role != RoleMember {
		t.Fatalf("unexpected redeem result %+v", res)
	}

	d, err := s.GetCircle(ctx, cid, bob.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Members) != 2 || d.MyWrappedKey != nil {
		t.Fatalf("members=%d wrapped=%v", len(d.Members), d.MyWrappedKey)
	}

	list, err := s.ListCircles(ctx, bob.ID)
	if err != nil || len(list) != 1 || list[0].Role != RoleMember {
		t.Fatalf("list: %+v %v", list, err)
	}

	if err := s.UpdateMemberBlob(ctx, cid, bob.ID, []byte("bob-card-2")); err != nil {
		t.Fatal(err)
	}
	d, _ = s.GetCircle(ctx, cid, alice.ID)
	if string(d.Members[1].MemberBlob) != "bob-card-2" {
		t.Fatalf("blob not updated: %q", d.Members[1].MemberBlob)
	}
}

func TestInviteSingleUseExpiryAndWrongToken(t *testing.T) {
	s, clk := openTest(t, Options{})
	ctx := context.Background()
	alice, bob, carol := newDevice(t, s), newDevice(t, s), newDevice(t, s)
	cid, _, _ := s.CreateCircle(ctx, alice.ID, []byte("meta"), []byte("a"), []byte("k"))

	inv, token := newInvite(t, s, cid, alice.ID, time.Hour, 1)

	if _, err := s.RedeemInvite(ctx, inv.ID, bob.ID, randBytes(32), []byte("b")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("wrong token: %v", err)
	}
	if _, err := s.RedeemInvite(ctx, inv.ID, bob.ID, token, []byte("b")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RedeemInvite(ctx, inv.ID, carol.ID, token, []byte("c")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("used-up invite: %v", err)
	}

	inv2, token2 := newInvite(t, s, cid, alice.ID, time.Minute, 5)
	clk.t = clk.t.Add(2 * time.Minute)
	if _, err := s.RedeemInvite(ctx, inv2.ID, carol.ID, token2, []byte("c")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expired invite: %v", err)
	}
	n, err := s.PurgeExpiredInvites(ctx)
	if err != nil || n != 1 {
		t.Fatalf("purge: n=%d err=%v", n, err)
	}
}

func TestInviteMultiUseAndAlreadyMember(t *testing.T) {
	s, _ := openTest(t, Options{})
	ctx := context.Background()
	alice, bob, carol := newDevice(t, s), newDevice(t, s), newDevice(t, s)
	cid, _, _ := s.CreateCircle(ctx, alice.ID, []byte("meta"), []byte("a"), []byte("k"))
	inv, token := newInvite(t, s, cid, alice.ID, time.Hour, 3)

	if _, err := s.RedeemInvite(ctx, inv.ID, alice.ID, token, []byte("a")); !errors.Is(err, ErrConflict) {
		t.Fatalf("owner redeeming own invite: %v", err)
	}
	for _, d := range []Device{bob, carol} {
		if _, err := s.RedeemInvite(ctx, inv.ID, d.ID, token, []byte("x")); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.RedeemInvite(ctx, inv.ID, bob.ID, token, []byte("x")); !errors.Is(err, ErrConflict) {
		t.Fatalf("double join: %v", err)
	}
}

func TestInviteRequiresMembershipAndLimits(t *testing.T) {
	s, _ := openTest(t, Options{MaxActiveInvitesPerCircle: 2, MaxMembersPerCircle: 2})
	ctx := context.Background()
	alice, bob, carol, mallory := newDevice(t, s), newDevice(t, s), newDevice(t, s), newDevice(t, s)
	cid, _, _ := s.CreateCircle(ctx, alice.ID, []byte("meta"), []byte("a"), []byte("k"))

	h := sha256.Sum256(randBytes(32))
	if _, err := s.CreateInvite(ctx, cid, mallory.ID, h[:], []byte("s"), time.Hour, 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-member invite: %v", err)
	}

	inv, token := newInvite(t, s, cid, alice.ID, time.Hour, 5)
	newInvite(t, s, cid, alice.ID, time.Hour, 1)
	if _, err := s.CreateInvite(ctx, cid, alice.ID, h[:], []byte("s"), time.Hour, 1); !errors.Is(err, ErrLimit) {
		t.Fatalf("invite limit: %v", err)
	}

	if _, err := s.RedeemInvite(ctx, inv.ID, bob.ID, token, []byte("b")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RedeemInvite(ctx, inv.ID, carol.ID, token, []byte("c")); !errors.Is(err, ErrLimit) {
		t.Fatalf("member limit: %v", err)
	}
}

func TestRevokeInvitePermissions(t *testing.T) {
	s, _ := openTest(t, Options{})
	ctx := context.Background()
	alice, bob, carol := newDevice(t, s), newDevice(t, s), newDevice(t, s)
	cid, _, _ := s.CreateCircle(ctx, alice.ID, []byte("meta"), []byte("a"), []byte("k"))
	for _, d := range []Device{bob, carol} {
		inv, tok := newInvite(t, s, cid, alice.ID, time.Hour, 1)
		if _, err := s.RedeemInvite(ctx, inv.ID, d.ID, tok, []byte("x")); err != nil {
			t.Fatal(err)
		}
	}
	bobInv, _ := newInvite(t, s, cid, bob.ID, time.Hour, 1)
	if err := s.RevokeInvite(ctx, cid, bobInv.ID, carol.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("carol revoking bob's invite: %v", err)
	}
	if err := s.RevokeInvite(ctx, cid, bobInv.ID, alice.ID); err != nil {
		t.Fatalf("owner revoke: %v", err)
	}
	if err := s.RevokeInvite(ctx, cid, bobInv.ID, alice.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second revoke: %v", err)
	}
}

func TestRemoveMemberRotatesKey(t *testing.T) {
	s, _ := openTest(t, Options{})
	ctx := context.Background()
	alice, bob, carol := newDevice(t, s), newDevice(t, s), newDevice(t, s)
	cid, _, _ := s.CreateCircle(ctx, alice.ID, []byte("meta"), []byte("a"), []byte("k1-alice"))
	for _, d := range []Device{bob, carol} {
		inv, tok := newInvite(t, s, cid, alice.ID, time.Hour, 1)
		if _, err := s.RedeemInvite(ctx, inv.ID, d.ID, tok, []byte("x")); err != nil {
			t.Fatal(err)
		}
	}
	pending, _ := newInvite(t, s, cid, alice.ID, time.Hour, 1)

	good := map[string][]byte{alice.ID: []byte("k2-alice"), carol.ID: []byte("k2-carol")}

	if _, err := s.RemoveMember(ctx, cid, bob.ID, carol.ID, 2, []byte("meta2"), good); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-owner remove: %v", err)
	}
	if _, err := s.RemoveMember(ctx, cid, alice.ID, bob.ID, 3, []byte("meta2"), good); !errors.Is(err, ErrConflict) {
		t.Fatalf("wrong epoch: %v", err)
	}
	if _, err := s.RemoveMember(ctx, cid, alice.ID, bob.ID, 2, []byte("meta2"), map[string][]byte{alice.ID: []byte("x")}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("missing wrapped key: %v", err)
	}
	withRemoved := map[string][]byte{alice.ID: []byte("x"), bob.ID: []byte("x")}
	if _, err := s.RemoveMember(ctx, cid, alice.ID, bob.ID, 2, []byte("meta2"), withRemoved); !errors.Is(err, ErrInvalid) {
		t.Fatalf("key for removed member: %v", err)
	}
	if _, err := s.RemoveMember(ctx, cid, alice.ID, alice.ID, 2, []byte("meta2"), good); !errors.Is(err, ErrInvalid) {
		t.Fatalf("self remove: %v", err)
	}
	if _, err := s.RemoveMember(ctx, cid, alice.ID, bob.ID, 2, nil, good); !errors.Is(err, ErrInvalid) {
		t.Fatalf("missing meta: %v", err)
	}

	epoch, err := s.RemoveMember(ctx, cid, alice.ID, bob.ID, 2, []byte("meta2"), good)
	if err != nil || epoch != 2 {
		t.Fatal(epoch, err)
	}
	if _, err := s.GetCircle(ctx, cid, bob.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("removed member still has access: %v", err)
	}
	d, err := s.GetCircle(ctx, cid, carol.ID)
	if err != nil || d.Epoch != 2 || string(d.MyWrappedKey) != "k2-carol" || len(d.Members) != 2 || string(d.MetaBlob) != "meta2" {
		t.Fatalf("after rotation: %+v %v", d, err)
	}
	if err := s.RevokeInvite(ctx, cid, pending.ID, alice.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("old invites must be revoked on rotation: %v", err)
	}
}

func TestLeavePromotesOwnerAndDeletesEmptyCircle(t *testing.T) {
	s, clk := openTest(t, Options{})
	ctx := context.Background()
	alice, bob := newDevice(t, s), newDevice(t, s)
	cid, _, _ := s.CreateCircle(ctx, alice.ID, []byte("meta"), []byte("a"), []byte("k"))
	clk.t = clk.t.Add(time.Second)
	inv, tok := newInvite(t, s, cid, alice.ID, time.Hour, 1)
	if _, err := s.RedeemInvite(ctx, inv.ID, bob.ID, tok, []byte("b")); err != nil {
		t.Fatal(err)
	}

	if err := s.Leave(ctx, cid, alice.ID); err != nil {
		t.Fatal(err)
	}
	list, _ := s.ListCircles(ctx, bob.ID)
	if len(list) != 1 || list[0].Role != RoleOwner {
		t.Fatalf("bob should be owner now: %+v", list)
	}
	if err := s.Leave(ctx, cid, bob.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.Leave(ctx, cid, bob.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("leave twice: %v", err)
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM circles`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("circles left: %d %v", n, err)
	}
}

func TestDeleteDeviceCleansUp(t *testing.T) {
	s, _ := openTest(t, Options{})
	ctx := context.Background()
	alice, bob := newDevice(t, s), newDevice(t, s)
	solo, _, _ := s.CreateCircle(ctx, alice.ID, []byte("meta"), []byte("a"), []byte("k"))
	shared, _, _ := s.CreateCircle(ctx, alice.ID, []byte("meta"), []byte("a"), []byte("k"))
	inv, tok := newInvite(t, s, shared, alice.ID, time.Hour, 1)
	if _, err := s.RedeemInvite(ctx, inv.ID, bob.ID, tok, []byte("b")); err != nil {
		t.Fatal(err)
	}

	if err := s.DeleteDevice(ctx, alice.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DeviceBySigningKey(ctx, alice.SigningKey); !errors.Is(err, ErrNotFound) {
		t.Fatalf("device still there: %v", err)
	}
	if _, err := s.GetCircle(ctx, solo, bob.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("solo circle: %v", err)
	}
	list, _ := s.ListCircles(ctx, bob.ID)
	if len(list) != 1 || list[0].ID != shared || list[0].Role != RoleOwner {
		t.Fatalf("bob after alice deleted: %+v", list)
	}
	if err := s.DeleteDevice(ctx, alice.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("delete twice: %v", err)
	}
}

func TestUpdateCircleMetaOwnerOnly(t *testing.T) {
	s, _ := openTest(t, Options{})
	ctx := context.Background()
	alice, bob := newDevice(t, s), newDevice(t, s)
	cid, _, _ := s.CreateCircle(ctx, alice.ID, []byte("meta"), []byte("a"), []byte("k"))
	inv, tok := newInvite(t, s, cid, alice.ID, time.Hour, 1)
	if _, err := s.RedeemInvite(ctx, inv.ID, bob.ID, tok, []byte("b")); err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateCircleMeta(ctx, cid, bob.ID, []byte("hijack")); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member update meta: %v", err)
	}
	if err := s.UpdateCircleMeta(ctx, cid, alice.ID, []byte("meta-v2")); err != nil {
		t.Fatal(err)
	}
	list, _ := s.ListCircles(ctx, bob.ID)
	if len(list) != 1 || string(list[0].MetaBlob) != "meta-v2" {
		t.Fatalf("list = %+v", list)
	}
}
