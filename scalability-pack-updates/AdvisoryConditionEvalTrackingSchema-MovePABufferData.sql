/*** Updated version of the SentryOne Scalability Pack Move procedure supporting Enhanced Advisory Condition Tracking ***/

USE SentryOne;

ALTER PROCEDURE [dbo].[MovePABufferData]
	@StaleDataThresholdInSeconds int
AS

SET NOCOUNT ON

DECLARE @MinStateThresholdDateTimeUtc datetime
SET @MinStateThresholdDateTimeUtc = DATEADD(SECOND, -@StaleDataThresholdInSeconds, GETUTCDATE())

DECLARE @StaleDevices TABLE
(
	ID bigint,
	DeviceID smallint,
	OriginalTimestamp int
)

DECLARE @CompletedConnections TABLE
(
	ConnectionObjectId uniqueidentifier
)

INSERT INTO @StaleDevices (ID, DeviceID, OriginalTimestamp)
SELECT
	 PerformanceAnalysisDataTempTableTracking.ID
	,PerformanceAnalysisDataTempTableTracking.DeviceID
	,PerformanceAnalysisDataTempTableTracking.Timestamp
FROM PerformanceAnalysisDataTempTableTracking
WHERE LastUpdatedUtc < @MinStateThresholdDateTimeUtc
  AND IsCompleted = 0;

UPDATE PerformanceAnalysisDataTempTableTracking
SET	 IsCompleted = 1
	,TimedOut = 1
FROM PerformanceAnalysisDataTempTableTracking
INNER JOIN @StaleDevices StaleDevices
   ON PerformanceAnalysisDataTempTableTracking.ID = StaleDevices.ID;

INSERT INTO PerformanceAnalysisDataTempTableLog (LogTimeUtc, DeviceID, OriginalTimestamp, LogType)
SELECT GETUTCDATE(), StaleDevices.DeviceID, StaleDevices.OriginalTimestamp, 0
FROM @StaleDevices StaleDevices;

DECLARE @CurrentTimestamp int
SET @CurrentTimestamp = dbo.GetCurrentTimestamp();

DECLARE @FirstIllegalTimestamp int
SET @FirstIllegalTimestamp =
(
	SELECT TOP 1 Timestamp
	FROM PerformanceAnalysisDataTempTableTracking
	GROUP BY Timestamp
	HAVING COUNT(*) > SUM(CAST(IsCompleted AS int))
	ORDER BY Timestamp ASC
);

-- If there are no invalid entries, then make the current time the invalid entry.
-- We can't process the current timestamp because it could still be assigned.
IF @FirstIllegalTimestamp IS NULL
	SET @FirstIllegalTimestamp = @CurrentTimestamp;

DECLARE @timestamp int;
DECLARE @sql nvarchar(2048);
DECLARE @params nvarchar(20);
DECLARE @database_id_string nvarchar(10);
DECLARE @timestamp_string nvarchar(20);
DECLARE @source_table nvarchar(255);
DECLARE @PartitionName nvarchar(256);
DECLARE @lastTimestampProcessed int;
DECLARE @ErrorNum int;
DECLARE @CCIenabled bit = 0;
DECLARE @ServiceID nvarchar(4);

DECLARE @ErrorNumber int;
DECLARE @ErrorSeverity int;
DECLARE @ErrorState int;
DECLARE @ErrorProcedure nvarchar(128);
DECLARE @ErrorLine int;
DECLARE @ErrorMessage nvarchar(4000);

SET @params = N'@timestamp int';
SET @database_id_string = CAST(DB_ID() AS nvarchar(10));
SET @lastTimestampProcessed = 0;

DECLARE timestamps_cursor CURSOR FAST_FORWARD
FOR
	SELECT DISTINCT(Timestamp)
	FROM PerformanceAnalysisDataTempTableTracking
	WHERE Timestamp < @FirstIllegalTimestamp
	  AND Timestamp < @CurrentTimestamp
	ORDER BY Timestamp ASC;

OPEN timestamps_cursor;

FETCH NEXT FROM timestamps_cursor INTO @timestamp;
WHILE @@FETCH_STATUS = 0
  BEGIN
	UPDATE PerformanceAnalysisDataTempTableCommitInfo
	SET CommitmentCutoff = @timestamp
	WHERE ID = 1;

	SET @timestamp_string = CAST(@timestamp AS nvarchar(20));
	
	DECLARE curPartition CURSOR FAST_FORWARD
	FOR
		SELECT N'' AS ObjectSuffix
	  UNION
		SELECT ObjectSuffix FROM PerformanceAnalysisCounterDataPartition
		ORDER BY ObjectSuffix;

	OPEN curPartition;

	DECLARE curSuffix CURSOR SCROLL READ_ONLY
	FOR
		SELECT ServiceID = N'0'
	  UNION
		SELECT ServiceID = CAST(ID as nvarchar(4))
		FROM ManagementEngine
		WHERE HeartbeatDateTime > DATEADD(day, -1, GETUTCDATE()) --go back a day in case service(s) stopped for an extended period.

	OPEN curSuffix;

	FETCH NEXT FROM curPartition INTO @PartitionName;
	WHILE @@FETCH_STATUS = 0
	  BEGIN		
		SET @CCIenabled = CASE WHEN EXISTS (SELECT pt.PartitionFunction FROM Partitioning.PartitionTracking pt WHERE pt.Suffix = @PartitionName AND pt.[Enabled] = 1) THEN 1 ELSE 0 END

		IF @CCIenabled = 1
		  BEGIN;
			BEGIN TRY
				EXECUTE Partitioning.CheckSplitNew @PartitionName, @timestamp
			END TRY
			BEGIN CATCH  
				SELECT  
					@ErrorNumber = ERROR_NUMBER(),
					@ErrorSeverity = ERROR_SEVERITY(),
					@ErrorState = ERROR_STATE(), 
					@ErrorProcedure = ERROR_PROCEDURE(), 
					@ErrorLine = ERROR_LINE(),
					@ErrorMessage = ERROR_MESSAGE();  

				INSERT INTO [Partitioning].[ActionErrorLogging]
				(
					[PartitionFunction],
					[Suffix],
					[Action],
					[ActionDesc],
					[ActionMessage],
					[ActionTime],
					[Boundary],
					[ErrorNumber],
					[ErrorSeverity],
					[ErrorState],
					[ErrorProcedure],
					[ErrorLine],
					[ErrorMessage]
				)
				VALUES
				(
					'PerformanceDataCurrentFunction' + @PartitionName,
					@PartitionName,
					0,
					'Error',
					'MovePABuffer',
					GETDATE(),
					@timestamp,
					@ErrorNumber,
					@ErrorSeverity,
					@ErrorState, 
					@ErrorProcedure, 
					@ErrorLine,
					@ErrorMessage 
				)
			END CATCH;

			/*** Move AC Evaluation Data into PAData ***/
			IF (@PartitionName = N'')
			  BEGIN
				--Update the most recent data for each device and counter with the current timestamp. Only these rows will be moved over to PAData.
				--We must do this here to ensure timestamps are aligned since we can't integrate directly with the PerformanceAnalysisDataTempTableTracking process.
				--Any earlier rows that exist at the time of update will be tagged for deletion later with a -1 to avoid impacting new rows that may be inserted in the interim.
				;WITH LastEvalTimestamps
				AS
				(
					SELECT
						 ConditionID
						,ObjectID
						,MAX(Timestamp) AS MaxTS
					FROM [Staging].[MO_DynamicConditionEvaluationResults]
					GROUP BY
						 ConditionID
						,ObjectID
				)
				UPDATE [Staging].[MO_DynamicConditionEvaluationResults]  
					SET TimestampAligned = CASE WHEN lt.MaxTS IS NULL THEN -1 ELSE @timestamp END
				FROM [Staging].[MO_DynamicConditionEvaluationResults] er
				LEFT OUTER JOIN LastEvalTimestamps lt
				  ON er.ConditionID = lt.ConditionID
				 AND er.ObjectID = lt.ObjectID
				 AND er.Timestamp = lt.MaxTS

				--Move AC evaluation results into counter data table.
				--We have to do this here because DeviceID and ConnectionID can't be evaluated from the mem-optimized trigger which collects the data,
				--since it would require joining to a non-MO table.
				INSERT INTO [Staging].[MO_PerformanceAnalysisData]
				(
					 [Timestamp]
					,[PerformanceAnalysisCounterID]
					,[DeviceID]
					,[EventSourceConnectionID]
					,[InstanceName]
					,[Value]
				)
				SELECT DISTINCT
					 er.[TimestampAligned]
					,er.[CounterID]
					,c.[DeviceID]
					,c.[ConnectionID]
					,er.[InstanceName]
					,er.[Value]
				FROM [Staging].[MO_DynamicConditionEvaluationResults] er
				JOIN 
					(
						SELECT
							 DeviceID = ID
							,ConnectionID = null
							,ObjectID
						FROM dbo.Device
						UNION ALL
						SELECT
							 DeviceID
							,ID
							,ObjectID
						FROM dbo.EventSourceConnection
					) c
				  ON c.ObjectID = er.ObjectID
				WHERE TimestampAligned = @timestamp;

				DELETE [Staging].[MO_DynamicConditionEvaluationResults]
				WHERE TimestampAligned = @timestamp
				   OR TimestampAligned = -1;
			  END
			/*** Move AC Evaluation Data into PAData ***/

			SET @sql =
				'INSERT INTO PerformanceAnalysisData' + @PartitionName + N'
					(Timestamp, PerformanceAnalysisCounterID, DeviceID, EventSourceConnectionID, InstanceName, Value)
				SELECT pa_data.Timestamp, pa_data.PerformanceAnalysisCounterID, pa_data.DeviceID, pa_data.EventSourceConnectionID, pa_data.InstanceName, pa_data.Value
				FROM Staging.MO_PerformanceAnalysisData' + @PartitionName + N' AS pa_data
				INNER JOIN PerformanceAnalysisDataTempTableTracking AS tracking
					 ON tracking.DeviceID = pa_data.DeviceID
					AND tracking.Timestamp = @timestamp
					AND tracking.TimedOut = 0
				WHERE pa_data.Timestamp = @timestamp;';
	
			EXEC sp_executesql @sql
						,@params
						,@timestamp=@timestamp;

			SET @ErrorNum = @@ERROR;
			IF @ErrorNum <> 0
			  BEGIN
				SELECT ErrorCode = @ErrorNum;
				GOTO ExitProc;
			  END

		  	--Successfully inserted, so cleanup table.
			SET @sql =
				'DELETE Staging.MO_PerformanceAnalysisData' + @PartitionName + N'
				WHERE Timestamp <= @timestamp;';
			EXEC sp_executesql @sql
						,@params
						,@timestamp=@timestamp;

			EXEC Partitioning.CompressRowGroups @PartitionName;
		  END
		ELSE
		  BEGIN
			--Loop through service-specific temp tables and build UNION.
			FETCH FIRST FROM curSuffix INTO @ServiceID;
			WHILE @@FETCH_STATUS = 0
			  BEGIN
				SET @source_table = 'tempdb.dbo.tmpPAData'+ @PartitionName + N'_' + @timestamp_string + N'_' + @database_id_string + N'_' + @ServiceID
				IF OBJECT_ID(@source_table) IS NOT NULL
				  BEGIN
					SET @sql = @sql +
						CASE WHEN @sql IS NOT NULL THEN	N'
					UNION
					' ELSE N'' END
					 + N'SELECT pa_data.Timestamp, pa_data.PerformanceAnalysisCounterID, pa_data.DeviceID, pa_data.EventSourceConnectionID, pa_data.InstanceName, SUM(pa_data.Value)
						FROM ' + @source_table + N' AS pa_data 
						INNER JOIN PerformanceAnalysisDataTempTableTracking tracking
						   ON pa_data.DeviceID = tracking.DeviceID
						  AND tracking.Timestamp = @timestamp
						  AND tracking.TimedOut = 0
						GROUP BY pa_data.Timestamp, pa_data.DeviceID, pa_data.PerformanceAnalysisCounterID, pa_data.EventSourceConnectionID, pa_data.InstanceName';
				  END

				FETCH NEXT FROM curSuffix INTO @ServiceID;
			  END;

			SET @sql =
				N'INSERT INTO PerformanceAnalysisData' + @PartitionName + N'
					(Timestamp, PerformanceAnalysisCounterID, DeviceID, EventSourceConnectionID, InstanceName, Value)
				' + @sql + N'
				ORDER BY pa_data.Timestamp, pa_data.DeviceID, pa_data.PerformanceAnalysisCounterID, pa_data.EventSourceConnectionID, pa_data.InstanceName;';

			EXEC sp_executesql @sql
						,@params
						,@timestamp=@timestamp;

			SET @ErrorNum = @@ERROR;
			IF @ErrorNum <> 0
			  BEGIN
				SELECT ErrorCode = @ErrorNum;
				GOTO ExitProc;
			  END

			--Successfully inserted, so cleanup tables.
			FETCH FIRST FROM curSuffix INTO @ServiceID;
			WHILE @@FETCH_STATUS = 0
			  BEGIN
				SET @source_table = 'tempdb.dbo.tmpPAData'+ @PartitionName + N'_' + @timestamp_string + N'_' + @database_id_string + N'_' + @ServiceID
				IF OBJECT_ID(@source_table) IS NOT NULL
				  BEGIN
		  			SET @sql = 'DROP TABLE ' + @source_table + ';';
					EXEC sp_executesql @sql;
				  END
				FETCH NEXT FROM curSuffix INTO @ServiceID;
			  END;

		  END;

		FETCH NEXT FROM curPartition INTO @PartitionName;		
	  END;

	CLOSE curSuffix;
	DEALLOCATE curSuffix;

	CLOSE curPartition;
	DEALLOCATE curPartition;	

	-- The data is updated. Finish by moving over the timestamps.
	UPDATE PerformanceAnalysisDevice SET LastCompletedTimeSampleID = TimeSampleID
	FROM PerformanceAnalysisDevice
	INNER JOIN PerformanceAnalysisDataTempTableTrackingSampleID
	   ON PerformanceAnalysisDataTempTableTrackingSampleID.PerformanceAnalysisDeviceID = PerformanceAnalysisDevice.ID
	INNER JOIN PerformanceAnalysisDataTempTableTracking
	   ON PerformanceAnalysisDataTempTableTrackingSampleID.PerformanceAnalysisDataTempTableTrackingID = PerformanceAnalysisDataTempTableTracking.ID
	WHERE PerformanceAnalysisDataTempTableTracking.Timestamp = @timestamp
	  AND PerformanceAnalysisDataTempTableTracking.DeviceID = PerformanceAnalysisDevice.DeviceID
	  AND PerformanceAnalysisDataTempTableTracking.TimedOut = 0;
	
	--*** MAKE SURE THAT BOTH OF THESE QUERIES (ABOVE/BELOW) USE THE SAME PREDICATES ON PerformanceAnalysisDataTempTableTracking ***
	 
	INSERT INTO @CompletedConnections
	SELECT EventSourceConnection.ObjectID
	FROM PerformanceAnalysisDevice
	INNER JOIN PerformanceAnalysisDataTempTableTrackingSampleID
	   ON PerformanceAnalysisDataTempTableTrackingSampleID.PerformanceAnalysisDeviceID = PerformanceAnalysisDevice.ID
	INNER JOIN PerformanceAnalysisDataTempTableTracking
	   ON PerformanceAnalysisDataTempTableTrackingSampleID.PerformanceAnalysisDataTempTableTrackingID = PerformanceAnalysisDataTempTableTracking.ID	
	INNER JOIN EventSourceConnection
	   ON EventSourceConnection.DeviceID = PerformanceAnalysisDataTempTableTracking.DeviceID	
	INNER JOIN Tasks.WatchTaskState
	   ON Tasks.WatchTaskState.ConnectionId = EventSourceConnection.ID
	  AND Tasks.WatchTaskState.ProductType = 1 /*PA*/
	  AND Tasks.WatchTaskState.State != 255 --watch complete
	WHERE PerformanceAnalysisDataTempTableTracking.Timestamp = @timestamp
	  AND PerformanceAnalysisDataTempTableTracking.DeviceID = PerformanceAnalysisDevice.DeviceID
	  AND PerformanceAnalysisDataTempTableTracking.TimedOut = 0;

	DELETE PerformanceAnalysisDataTempTableTrackingSampleID
	FROM PerformanceAnalysisDataTempTableTrackingSampleID
	INNER JOIN PerformanceAnalysisDataTempTableTracking
	   ON PerformanceAnalysisDataTempTableTrackingSampleID.PerformanceAnalysisDataTempTableTrackingID = PerformanceAnalysisDataTempTableTracking.ID
	WHERE PerformanceAnalysisDataTempTableTracking.Timestamp = @timestamp;
	
	CREATE TABLE #temp_ids (ID bigint);

	INSERT INTO #temp_ids (ID)
		SELECT ID FROM PerformanceAnalysisDataTempTableTracking WHERE Timestamp=@timestamp;

	DELETE PerformanceAnalysisDataTempTableTracking
	FROM PerformanceAnalysisDataTempTableTracking
	INNER JOIN #temp_ids temp_ids
	   ON PerformanceAnalysisDataTempTableTracking.ID = temp_ids.ID;

	DROP TABLE #temp_ids;
	
	SET @lastTimestampProcessed = @timestamp;
	FETCH NEXT FROM timestamps_cursor INTO @timestamp;
  END

INSERT INTO Tasks.MovePABufferDataCompletedConnections
	SELECT DISTINCT ConnectionObjectId
	FROM @CompletedConnections

ExitProc:
	CLOSE timestamps_cursor
	DEALLOCATE timestamps_cursor

	SELECT @lastTimestampProcessed AS LastTimestampProcessed

