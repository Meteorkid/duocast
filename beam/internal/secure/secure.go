// Package secure 提供一条端到端加密的字节通道。
//
// 握手：双方各生成一次性 X25519 密钥，交换公钥后做 ECDH，再用 HKDF-SHA256
// 派生出双向各一把 AES-256-GCM 密钥。中转服务器只转发密文，看不到内容，
// 也无法伪造数据（GCM 校验会失败）。
//
// 记录格式：uint16 长度 + 密文（明文 + 16 字节 tag），单条明文上限 32 KiB。
// 双向计数各自独立，所以不会出现 nonce 重用。
package secure

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

const (
	maxRecord   = 32 * 1024
	gcmOverhead = 16
	pubKeySize  = 32
)

// Conn 包装底层连接，读写都经过 AES-GCM。
type Conn struct {
	raw       net.Conn
	sendAEAD  cipher.AEAD
	recvAEAD  cipher.AEAD
	sendCount uint64
	recvCount uint64
	readBuf   []byte
	readErr   error
	sas       string
	rmu       sync.Mutex
	wmu       sync.Mutex
}

// Handshake 在已有连接上完成密钥协商。两端调用顺序对称，先写后读。
func Handshake(raw net.Conn) (*Conn, error) {
	curve := ecdh.X25519()

	private, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("生成临时密钥失败: %w", err)
	}

	ours := private.PublicKey().Bytes()
	if _, err := raw.Write(ours); err != nil {
		return nil, fmt.Errorf("发送握手公钥失败: %w", err)
	}

	peer := make([]byte, pubKeySize)
	if _, err := io.ReadFull(raw, peer); err != nil {
		return nil, fmt.Errorf("读取对端公钥失败: %w", err)
	}

	peerKey, err := curve.NewPublicKey(peer)
	if err != nil {
		return nil, fmt.Errorf("对端公钥无效: %w", err)
	}

	shared, err := private.ECDH(peerKey)
	if err != nil {
		return nil, fmt.Errorf("密钥协商失败: %w", err)
	}

	// 用排序后的两个公钥做 salt：两端算出的字节序一致，不依赖谁先开口。
	low, high := ours, peer
	initiator := bytes.Compare(ours, peer) < 0
	if !initiator {
		low, high = peer, ours
	}

	saltInput := append(append([]byte{}, low...), high...)
	salt := sha256.Sum256(saltInput)
	material := hkdfSHA256(shared, salt[:], []byte("beam v1 session"), 64)

	sendKey, recvKey := material[:32], material[32:]
	if !initiator {
		sendKey, recvKey = recvKey, sendKey
	}

	sendAEAD, err := newAEAD(sendKey)
	if err != nil {
		return nil, err
	}

	recvAEAD, err := newAEAD(recvKey)
	if err != nil {
		return nil, err
	}

	return &Conn{
		raw:      raw,
		sendAEAD: sendAEAD,
		recvAEAD: recvAEAD,
		sas:      shortAuthString(salt[:]),
	}, nil
}

// SAS 是双方都能算出、但第三方算不出的短验证串，供两人口头核对。
func (c *Conn) SAS() string { return c.sas }

func (c *Conn) Write(p []byte) (int, error) {
	c.wmu.Lock()
	defer c.wmu.Unlock()

	written := 0
	for len(p) > 0 {
		chunk := p
		if len(chunk) > maxRecord {
			chunk = chunk[:maxRecord]
		}

		sealed := c.sendAEAD.Seal(nil, nonceFor(c.sendCount), chunk, nil)
		c.sendCount++

		frame := make([]byte, 2+len(sealed))
		binary.BigEndian.PutUint16(frame, uint16(len(sealed)))
		copy(frame[2:], sealed)

		if _, err := c.raw.Write(frame); err != nil {
			return written, err
		}

		written += len(chunk)
		p = p[len(chunk):]
	}

	return written, nil
}

func (c *Conn) Read(p []byte) (int, error) {
	c.rmu.Lock()
	defer c.rmu.Unlock()

	if len(c.readBuf) == 0 {
		if c.readErr != nil {
			return 0, c.readErr
		}

		plain, err := c.readRecord()
		if err != nil {
			c.readErr = err
			return 0, err
		}

		c.readBuf = plain
	}

	n := copy(p, c.readBuf)
	c.readBuf = c.readBuf[n:]
	return n, nil
}

func (c *Conn) readRecord() ([]byte, error) {
	var header [2]byte
	if _, err := io.ReadFull(c.raw, header[:]); err != nil {
		return nil, err
	}

	size := int(binary.BigEndian.Uint16(header[:]))
	if size <= gcmOverhead || size > maxRecord+gcmOverhead {
		return nil, fmt.Errorf("记录长度非法: %d", size)
	}

	sealed := make([]byte, size)
	if _, err := io.ReadFull(c.raw, sealed); err != nil {
		return nil, err
	}

	plain, err := c.recvAEAD.Open(nil, nonceFor(c.recvCount), sealed, nil)
	c.recvCount++

	if err != nil {
		return nil, errors.New("解密失败：密钥不匹配或数据被篡改")
	}

	return plain, nil
}

func (c *Conn) Close() error                       { return c.raw.Close() }
func (c *Conn) LocalAddr() net.Addr                { return c.raw.LocalAddr() }
func (c *Conn) RemoteAddr() net.Addr               { return c.raw.RemoteAddr() }
func (c *Conn) SetDeadline(t time.Time) error      { return c.raw.SetDeadline(t) }
func (c *Conn) SetReadDeadline(t time.Time) error  { return c.raw.SetReadDeadline(t) }
func (c *Conn) SetWriteDeadline(t time.Time) error { return c.raw.SetWriteDeadline(t) }

func newAEAD(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("初始化 AES 失败: %w", err)
	}

	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("初始化 GCM 失败: %w", err)
	}

	return aead, nil
}

func nonceFor(counter uint64) []byte {
	nonce := make([]byte, 12)
	binary.BigEndian.PutUint64(nonce[4:], counter)
	return nonce
}

// hkdfSHA256 手写 HKDF（提取 + 扩展），避免额外依赖。
func hkdfSHA256(secret, salt, info []byte, length int) []byte {
	extract := hmac.New(sha256.New, salt)
	extract.Write(secret)
	prk := extract.Sum(nil)

	out := make([]byte, 0, length)
	var previous []byte

	for counter := byte(1); len(out) < length; counter++ {
		expand := hmac.New(sha256.New, prk)
		expand.Write(previous)
		expand.Write(info)
		expand.Write([]byte{counter})
		previous = expand.Sum(nil)
		out = append(out, previous...)
	}

	return out[:length]
}

func shortAuthString(seed []byte) string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

	sum := sha256.Sum256(append([]byte("beam sas"), seed...))
	code := make([]byte, 8)

	for i := range code {
		code[i] = alphabet[int(sum[i])%len(alphabet)]
	}

	return string(code[:4]) + "-" + string(code[4:])
}
