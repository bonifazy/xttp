package splithttp

import (
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/xtls/xray-core/common/crypto"
)

// telemt #844: режем только первый TLS ClientHello. Остальной TCP не трогаем.
func helloFragEnabled() bool {
	v := strings.TrimSpace(os.Getenv("XRAY_HELLO_FRAG"))
	return v != "0" && v != "false" && v != "off"
}

func wrapHelloFrag(conn net.Conn) net.Conn {
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	lenFrom, lenTo := parseEnvRange("XRAY_HELLO_FRAG_LENGTH", 80, 120)
	intFrom, intTo := parseEnvRange("XRAY_HELLO_FRAG_INTERVAL", 8, 20)
	return &helloFragConn{
		Conn:    conn,
		lenFrom: lenFrom,
		lenTo:   lenTo,
		intFrom: intFrom,
		intTo:   intTo,
	}
}

func parseEnvRange(key string, defFrom, defTo int) (int, int) {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return defFrom, defTo
	}
	from, to := defFrom, defTo
	if a, b, ok := strings.Cut(raw, "-"); ok {
		if n, err := strconv.Atoi(strings.TrimSpace(a)); err == nil && n > 0 {
			from = n
		}
		if n, err := strconv.Atoi(strings.TrimSpace(b)); err == nil && n > 0 {
			to = n
		}
	} else if n, err := strconv.Atoi(raw); err == nil && n > 0 {
		from, to = n, n
	}
	if from > to {
		from, to = to, from
	}
	return from, to
}

type helloFragConn struct {
	net.Conn
	done               bool
	lenFrom, lenTo     int
	intFrom, intTo     int
}

func (c *helloFragConn) Write(b []byte) (int, error) {
	if c.done {
		return c.Conn.Write(b)
	}
	c.done = true
	if len(b) <= 5 || b[0] != 22 {
		return c.Conn.Write(b)
	}
	recordLen := 5 + ((int(b[3]) << 8) | int(b[4]))
	if len(b) < recordLen {
		return c.Conn.Write(b)
	}
	data := b[5:recordLen]
	buff := make([]byte, 2048)
	for from := 0; from < len(data); {
		to := from + int(crypto.RandBetween(int64(c.lenFrom), int64(c.lenTo)+1))
		if to > len(data) {
			to = len(data)
		}
		l := to - from
		if 5+l > len(buff) {
			buff = make([]byte, 5+l)
		}
		copy(buff[:3], b)
		copy(buff[5:], data[from:to])
		buff[3] = byte(l >> 8)
		buff[4] = byte(l)
		if _, err := c.Conn.Write(buff[:5+l]); err != nil {
			return 0, err
		}
		from = to
		if from < len(data) && (c.intFrom > 0 || c.intTo > 0) {
			time.Sleep(time.Duration(crypto.RandBetween(int64(c.intFrom), int64(c.intTo)+1)) * time.Millisecond)
		}
	}
	if len(b) > recordLen {
		n, err := c.Conn.Write(b[recordLen:])
		if err != nil {
			return recordLen + n, err
		}
	}
	return len(b), nil
}

var _ io.Writer = (*helloFragConn)(nil)
