CREATE OR REPLACE FUNCTION dex.insert_oneinch(start_ts timestamptz, end_ts timestamptz=now(), start_block numeric=0, end_block numeric=9e18) RETURNS integer
LANGUAGE plpgsql AS $function$
DECLARE r integer;
BEGIN
WITH rows AS (
    INSERT INTO dex.trades (
        block_time,
        token_a_symbol,
        token_b_symbol,
        token_a_amount,
        token_b_amount,
        project,
        version,
        category,
        trader_a,
        trader_b,
        token_a_amount_raw,
        token_b_amount_raw,
        usd_amount,
        token_a_address,
        token_b_address,
        exchange_contract_address,
        tx_hash,
        tx_from,
        tx_to,
        trace_address,
        evt_index,
        trade_id
    )
    SELECT
        dexs.block_time,
        erc20a.symbol AS token_a_symbol,
        erc20b.symbol AS token_b_symbol,
        token_a_amount_raw / 10 ^ erc20a.decimals AS token_a_amount,
        token_b_amount_raw / 10 ^ erc20b.decimals AS token_b_amount,
        project,
        version,
        category,
        coalesce(trader_a, tx."from") as trader_a, -- subqueries rely on this COALESCE to avoid redundant joins with the transactions table
        trader_b,
        token_a_amount_raw,
        token_b_amount_raw,
        coalesce(
            usd_amount,
            token_a_amount_raw / 10 ^ pa.decimals * pa.median_price,
            token_b_amount_raw / 10 ^ pb.decimals * pb.median_price
        ) as usd_amount,
        token_a_address,
        token_b_address,
        exchange_contract_address,
        tx_hash,
        tx."from" as tx_from,
        tx."to" as tx_to,
        trace_address,
        evt_index,
        row_number() OVER (PARTITION BY project, tx_hash, evt_index, trace_address ORDER BY version, category) AS trade_id
    FROM (
        --AggregationRouterV3
        SELECT
            t.evt_block_time AS block_time,
            '1inch' AS project,
            '3' AS version,
            'Aggregator' AS category,
            "dstReceiver" AS trader_a,
            NULL::bytea AS trader_b,
            --Token a is what was received 
            "returnAmount" AS token_a_amount_raw,
            "spentAmount" AS token_b_amount_raw,
            NULL::numeric AS usd_amount,
	    --map default eth to OP Eth dead address
            CASE WHEN "dstToken" = '\xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' THEN '\xdeaddeaddeaddeaddeaddeaddeaddeaddead0000'::bytea ELSE "dstToken" END AS token_a_address,
            CASE WHEN "srcToken" = '\xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' THEN '\xdeaddeaddeaddeaddeaddeaddeaddeaddead0000'::bytea ELSE "srcToken" END AS token_b_address,
            t.contract_address as exchange_contract_address,
            t.evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            t.evt_index
        FROM
            oneinch."AggregationRouterV3_evt_Swapped" t

        WHERE t.evt_block_time >= start_ts AND t.evt_block_time < end_ts
	
	--TODO: UNION ALL AggregationRouterV4 Once it's decoded

    ) dexs
    INNER JOIN optimism.transactions tx
        ON dexs.tx_hash = tx.hash
        AND tx.block_time >= start_ts
        AND tx.block_time < end_ts
        AND tx.block_number >= start_block
        AND tx.block_number < end_block
    LEFT JOIN erc20.tokens erc20a ON erc20a.contract_address = dexs.token_a_address
    LEFT JOIN erc20.tokens erc20b ON erc20b.contract_address = dexs.token_b_address
    LEFT JOIN prices.approx_prices_from_dex_data pa
      ON pa.hour = date_trunc('hour', dexs.block_time)
        AND pa.contract_address = dexs.token_a_address
        AND pa.hour >= start_ts
        AND pa.hour < end_ts
    LEFT JOIN prices.approx_prices_from_dex_data pb
      ON pb.hour = date_trunc('hour', dexs.block_time)
        AND pb.contract_address = dexs.token_b_address
        AND pb.hour >= start_ts
        AND pb.hour < end_ts

    -- update if we have new info on prices or the erc20
    ON CONFLICT (project, tx_hash, evt_index, trade_id)
    DO UPDATE SET
        usd_amount = EXCLUDED.usd_amount,
        token_a_amount = EXCLUDED.token_a_amount,
        token_b_amount = EXCLUDED.token_b_amount,
        token_a_symbol = EXCLUDED.token_a_symbol,
        token_b_symbol = EXCLUDED.token_b_symbol
    RETURNING 1
)
SELECT count(*) INTO r from rows;
RETURN r;
END
$function$;

-- table start fill
SELECT dex.insert_oneinch(
    '2021-11-11',
    now(),
    0,
    (SELECT MAX(number) FROM optimism.blocks where time < now() - interval '20 minutes')
)
WHERE NOT EXISTS (
    SELECT *
    FROM dex.trades
    WHERE block_time > '2021-11-10'
    AND block_time <= now() - interval '20 minutes'
    AND project = '1inch' AND version = '3'
);

INSERT INTO cron.job (schedule, command)
VALUES ('15,45 * * * *', $$
    SELECT dex.insert_oneinch(
        (SELECT max(block_time) - interval '1 days' FROM dex.trades WHERE project='1Inch' AND version = '3'),
        (SELECT now() - interval '20 minutes'),
        (SELECT max(number) FROM optimism.blocks WHERE time < (SELECT max(block_time) - interval '1 days' FROM dex.trades WHERE project='Uniswap' AND version = '3')),
        (SELECT MAX(number) FROM optimism.blocks where time < now() - interval '20 minutes'));
$$)
ON CONFLICT (command) DO UPDATE SET schedule=EXCLUDED.schedule;
