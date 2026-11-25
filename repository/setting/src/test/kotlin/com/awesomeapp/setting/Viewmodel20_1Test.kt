package com.awesomeapp.setting

import org.junit.Test
import org.junit.Before
import org.junit.runner.RunWith
import org.junit.runners.JUnit4
import org.junit.Rule
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.*
import kotlin.test.assertTrue
import kotlin.test.assertNotNull
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import com.awesomeapp.setting.*
import com.awesomeapp.setting.Repository20_5


@OptIn(ExperimentalCoroutinesApi::class)
class Viewmodel20_1Test {
        private lateinit var repository0: Repository20_5

    private lateinit var viewModel: Viewmodel20_1

    @Before
    fun setup() {
       repository0 = Repository20_5(com.awesomeapp.setting.Api20_6())
        viewModel = Viewmodel20_1(
            repository0
        )
    }

    @Test
    fun `test state updates with data`() = runTest {
        assertNotNull(viewModel.state.value)
    }
}
