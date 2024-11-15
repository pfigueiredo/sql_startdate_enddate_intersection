DECLARE @ToleranceStep INT = 10;

--Expected Schedule
SELECT * INTO #Expected FROM (
	SELECT CAST('2024-01-01 17:55:00' AS DATETIME) StartTime, CAST('2024-01-01 18:00:00' AS DATETIME) EndTime, 'Other'     IntervalType, 1 HasTolerance UNION ALL
	SELECT CAST('2024-01-01 18:00:00' AS DATETIME) StartTime, CAST('2024-01-01 18:05:00' AS DATETIME) EndTime, 'Work'      IntervalType, 1 HasTolerance UNION ALL
	SELECT CAST('2024-01-01 18:05:00' AS DATETIME) StartTime, CAST('2024-01-01 22:00:00' AS DATETIME) EndTime, 'Work'      IntervalType, 0 HasTolerance UNION ALL
	SELECT CAST('2024-01-01 22:00:00' AS DATETIME) StartTime, CAST('2024-01-01 23:00:00' AS DATETIME) EndTime, 'Meal'      IntervalType, 0 HasTolerance UNION ALL
	SELECT CAST('2024-01-01 23:00:00' AS DATETIME) StartTime, CAST('2024-01-02 03:00:00' AS DATETIME) EndTime, 'Work'      IntervalType, 0 HasTolerance UNION ALL
	SELECT CAST('2024-01-01 22:00:00' AS DATETIME) StartTime, CAST('2024-01-02 08:00:00' AS DATETIME) EndTime, 'Norturnal' IntervalType, 0 HasTolerance
) T

--Actual Working Time
SELECT * INTO #Actual FROM (
	SELECT CAST('2024-01-01 18:05:00' AS DATETIME) StartTime, CAST('2024-01-01 22:15:00' AS DATETIME) EndTime, 'Presence' IntervalType UNION ALL
	SELECT CAST('2024-01-01 23:35:00' AS DATETIME) StartTime, CAST('2024-01-02 03:29:00' AS DATETIME) EndTime, 'Presence' IntervalType
) T
SELECT * FROM #Expected
SELECT * FROM #Actual

--Step 1 create start and stop list
DECLARE @Groups TABLE (
	N INT,
	[Time] DATETIME,
	IntervalType VARCHAR(Max),
	[Type] VARCHAR(10),
	[All] VARCHAR(Max),
	HasTolerance Bit
)

DECLARE @Output TABLE (
	StartTime DATETIME,
	EndTime DATETIME,
	[Type] VARCHAR(Max),
	HasTolerance Bit,
	Duration DECIMAL(10,2),
	Presence DECIMAL(10,2),
	Absence DECIMAL(10,2),
	Extra DECIMAL(10,2),
	Norturnal DECIMAL(10,2)
)

--insert start and stop list
INSERT INTO @Groups (N, [Time], IntervalType, [Type], HasTolerance)
SELECT 
	ROW_NUMBER() OVER (ORDER BY [Time], CASE WHEN [Type] = 'End' THEN 0 ELSE 1 END) N,
	[Time], 
	[IntervalType], 
	[Type],
	HasTolerance
FROM (
	SELECT StartTime [Time], IntervalType, 'Start' [Type], HasTolerance   FROM #Expected UNION ALL
	SELECT StartTime [Time], IntervalType, 'Start' [Type], 0 HasTolerance FROM #Actual   UNION ALL
	SELECT EndTime   [Time], IntervalType, 'End'   [Type], HasTolerance   FROM #Expected UNION ALL
	SELECT EndTime   [Time], IntervalType, 'End'   [Type], 0 HasTolerance FROM #Actual
) T ORDER BY 1

--SELECT * FROM @Groups


DECLARE C CURSOR
FOR SELECT [Time], IntervalType, [Type], [All], [HasTolerance] FROM @Groups
OPEN C

DECLARE @Buffer NVARCHAR(MAX) = '{}'
DECLARE @ToleranceBuffer BIT = 0
DECLARE @Time DATETIME, @IntervalType VARCHAR(MAX), @Type VARCHAR(10), @All VARCHAR(MAX), @HasTolerance BIT

--for each line classify group type
FETCH NEXT FROM C INTO @Time, @IntervalType, @Type, @All, @HasTolerance
WHILE @@FETCH_STATUS = 0
BEGIN

	IF @Type = 'Start'
	BEGIN 
		SET @Buffer = JSON_MODIFY(@Buffer, 'lax $.' + @IntervalType, 'true')
		IF @HasTolerance = 1 SET @ToleranceBuffer = 1
	END

	IF @Type = 'End' AND JSON_VALUE(@Buffer, '$.' + @IntervalType) = 'true'
	BEGIN 
		IF @HasTolerance = 1 SET @ToleranceBuffer = 0
		SET @Buffer = JSON_MODIFY(@Buffer, 'lax $.' + @IntervalType, NULL)
	END

	SET @All = @Buffer
	SET @HasTolerance = @ToleranceBuffer

	UPDATE @Groups
	SET 
		[All] = @All,
		[HasTolerance] = @HasTolerance
	WHERE CURRENT OF C

	FETCH NEXT FROM C INTO @Time, @IntervalType, @Type, @All, @HasTolerance
END

CLOSE C
DEALLOCATE C

--Calculate time (slip into Presence, Absence, Extra and Norturnal and apply tolerance)
INSERT INTO @Output (StartTime, EndTime, [Type], HasTolerance, Duration, Presence, Absence, Extra, Norturnal)
SELECT 
	N1.Time AS StartTime, 
	N2.Time EndTime, 
	N1.[All],
	N1.HasTolerance,
	DATEDIFF(MINUTE, N1.Time, N2.Time) Duration,
	CASE WHEN JSON_VALUE(N1.[All], '$.Presence') = 'true' AND JSON_VALUE(N1.[All], '$.Work') = 'true' THEN DATEDIFF(MINUTE, N1.Time, N2.Time) ELSE 0 END Presence,
	CASE WHEN ISNULL(JSON_VALUE(N1.[All], '$.Presence'), 'false') <> 'true' AND JSON_VALUE(N1.[All], '$.Work') = 'true' THEN DATEDIFF(MINUTE, N1.Time, N2.Time) ELSE 0 END Absence,
	CASE WHEN JSON_VALUE(N1.[All], '$.Presence') = 'true' AND ISNULL(JSON_VALUE(N1.[All], '$.Work'), 'false') <> 'true' THEN DATEDIFF(MINUTE, N1.Time, N2.Time) ELSE 0 END Extra,
	CASE WHEN JSON_VALUE(N1.[All], '$.Presence') = 'true' AND ISNULL(JSON_VALUE(N1.[All], '$.Norturnal'), 'false') = 'true' THEN DATEDIFF(MINUTE, N1.Time, N2.Time) ELSE 0 END Norturnal
FROM @Groups N1
	LEFT JOIN @Groups N2 ON N1.N = N2.N -1

DELETE FROM @Output WHERE StartTime = EndTime

UPDATE O SET Presence = Absence, Absence = Presence
FROM @Output O WHERE Absence > 0 AND Absence <= @ToleranceStep AND HasTolerance = 1
UPDATE O SET Presence = Extra, Extra = Presence
FROM @Output O WHERE Extra > 0 AND Extra <= @ToleranceStep AND HasTolerance = 1

SELECT * FROM @Output

DROP TABLE #Expected
DROP TABLE #Actual
