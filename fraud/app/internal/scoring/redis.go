package scoring

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"github.com/redis/go-redis/v9"
	"strconv"
)

// One pipelined EVAL atomically reads the previous location and updates all windows.
// Timestamped merchant/card members expire individually, unlike a plain set TTL.
const featureScript = `
local cached = redis.call('GET',KEYS[7])
if cached then return cjson.decode(cached) end
local t = tonumber(ARGV[1])
redis.call('ZADD',KEYS[1],t,ARGV[2])
redis.call('ZREMRANGEBYSCORE',KEYS[1],'-inf',t-900000)
redis.call('ZREMRANGEBYSCORE',KEYS[2],'-inf',t-600000)
if tonumber(ARGV[3]) < 500 then redis.call('ZADD',KEYS[2],t,ARGV[2]) end
redis.call('ZADD',KEYS[3],t,ARGV[4])
redis.call('ZREMRANGEBYSCORE',KEYS[3],'-inf',t-600000)
local last = redis.call('GET',KEYS[4]) or ''
if ARGV[8] ~= 'online' then redis.call('SET',KEYS[4],ARGV[5],'EX',3600) end
redis.call('SET',KEYS[5],ARGV[6],'NX','EX',86400)
redis.call('ZREMRANGEBYSCORE',KEYS[6],'-inf',t-60000)
if tonumber(ARGV[3]) <= 200 then redis.call('ZADD',KEYS[6],t,ARGV[7]) end
for _,i in ipairs({1,2,3,6}) do redis.call('EXPIRE',KEYS[i],3600) end
local result = {redis.call('ZCOUNT',KEYS[1],t-60000,t),redis.call('ZCOUNT',KEYS[1],t-600000,t),redis.call('ZCARD',KEYS[2]),redis.call('ZCARD',KEYS[3]),redis.call('ZCARD',KEYS[6]),last,redis.call('GET',KEYS[5])}
redis.call('SET',KEYS[7],cjson.encode(result),'EX',3600)
return result
`

func Fetch(ctx context.Context, client *redis.Client, req model.AuthRequest) (Features, error) {
	loc, _ := json.Marshal(Location{Lat: req.Lat, Lon: req.Lon, City: req.City, Country: req.Country, TS: req.TS})
	prefix := "card:" + req.CardID + ":"
	p := client.Pipeline()
	cmd := p.Eval(ctx, featureScript, []string{prefix + "txns", prefix + "small", prefix + "merchants", prefix + "location", prefix + "home", "bin:" + req.BIN, "features:" + req.TxnID}, req.TS.UnixMilli(), req.TxnID, req.AmountCents, req.MerchantID, string(loc), req.Country, req.CardID, req.City)
	if _, err := p.Exec(ctx); err != nil {
		return Features{}, err
	}
	values, err := cmd.Slice()
	if err != nil {
		return Features{}, err
	}
	if len(values) != 7 {
		return Features{}, fmt.Errorf("unexpected feature count %d", len(values))
	}
	integer := func(i int) int { v, _ := strconv.Atoi(fmt.Sprint(values[i])); return v }
	f := Features{Count60: integer(0), Count10: integer(1), Small10: integer(2), Merchants10: integer(3), BINCards60: integer(4), HomeCountry: fmt.Sprint(values[6])}
	if s := fmt.Sprint(values[5]); s != "" {
		if err := json.Unmarshal([]byte(s), &f.Last); err != nil {
			return Features{}, err
		}
	}
	f.Travel(req)
	return f, nil
}
